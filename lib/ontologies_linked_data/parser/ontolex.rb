require 'rdf'
require 'rdf/turtle'
require 'rdf/ntriples'
require 'addressable/uri'
require 'cgi'
require 'set'
require 'tempfile'

module LinkedData
  module Parser
    class OntoLexParser
      attr_accessor :logger

      def initialize(submission, file_path)
        @submission = submission
        @file_path = file_path
        @logger = nil
      end

      def parse
        @logger&.info("Starting OntoLex parsing from #{@file_path}")
        output_path = File.join(File.dirname(@file_path), 'ontolex_triples.ttl')
        OntoLex.parse(@file_path, @submission)
        @logger&.info('OntoLex parsing completed')
        output_path
      end
    end

    class OntoLex
      ONTOLEX   = RDF::Vocabulary.new('http://www.w3.org/ns/lemon/ontolex#')
      LEXINFO   = RDF::Vocabulary.new('http://www.lexinfo.net/ontology/3.0/lexinfo#')
      VARTRANS  = RDF::Vocabulary.new('http://www.w3.org/ns/lemon/vartrans#')
      SKOS      = RDF::Vocabulary.new('http://www.w3.org/2004/02/skos/core#')
      DCTERMS   = RDF::Vocabulary.new('http://purl.org/dc/terms/')
      TERMLEX   = RDF::Vocabulary.new('https://termlex.oeg.fi.upm.es/termlex/')
      LEXICOG   = RDF::Vocabulary.new('http://www.w3.org/ns/lemon/lexicog#')
      ETV       = RDF::Vocabulary.new('https://w3id.org/def/easytv#')
      PROV      = RDF::Vocabulary.new('http://www.w3.org/ns/prov#')
      FOAF      = RDF::Vocabulary.new('http://xmlns.com/foaf/0.1/')
      DBO       = RDF::Vocabulary.new('http://dbpedia.org/ontology/')
      OLIA      = RDF::Vocabulary.new('http://purl.org/olia/olia.owl#')
      OWL       = RDF::Vocabulary.new('http://www.w3.org/2002/07/owl#')
      RICO      = RDF::Vocabulary.new('https://www.ica.org/standards/RiC/ontology#')
      RDF_NS    = RDF::Vocabulary.new('https://www.w3.org/1999/02/22-rdf-syntax-ns#')
      DUL       = RDF::Vocabulary.new('http://www.ontologydesignpatterns.org/ont/dul/DUL.owl#')
      RDF_TYPE  = [
        RDF::URI('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
        RDF::URI('https://www.w3.org/1999/02/22-rdf-syntax-ns#type')
      ]

      # ---------------------------------------------------------------------------
      # Batch insert size constants
      # ---------------------------------------------------------------------------
      SYNC_BATCH_SIZE    = 500    # triples per INSERT DATA in sync_submission_graph
      MAPPING_BATCH_SIZE = 1000   # triples per INSERT DATA in generate_mapping_triples

      class << self
        def parse(rdf_source, submission, options = {})
          raise ArgumentError, 'submission is required' unless submission
          submission.bring(:ontology) if submission.respond_to?(:bring) && !submission.ontology

          graph = load_graph(rdf_source)
          sync_submission_graph(graph, submission)

          # Build in-memory indices once — avoids O(n) graph scans per lookup
          @type_index  = build_type_index(graph)
          @prop_index  = build_prop_index(graph)

          warn("[OntoLex] Graph: #{graph.count} triples | " \
               "SKOSConcepts=#{type_subjects(SKOS.Concept).size} " \
               "LexicalConcepts=#{type_subjects(ONTOLEX.LexicalConcept).size} " \
               "LexicalEntries=#{type_subjects(ONTOLEX.LexicalEntry).size} " \
               "LexicalSenses=#{type_subjects(ONTOLEX.LexicalSense).size} " \
               "Forms=#{type_subjects(ONTOLEX.Form).size}")

          # Parse auxiliary entities first so they exist when main entities reference them
          references        = index_references(graph, submission)
          activities        = index_activities(graph, submission)
          agents            = index_agents(graph, submission)
          definitions       = index_definitions(graph, submission)
          notes             = index_notes(graph, submission)
          usage_examples    = index_usage_examples(graph, submission)
          usages            = index_usages(graph, submission)
          videos_by_id      = index_videos(graph, submission)
          signed_forms_by_id = index_signed_forms(graph, submission, videos_by_id)

          skos_concepts_by_id, skos_concepts = index_skos_concepts(graph, submission)
          concepts_by_id, concepts           = index_concepts(graph, submission, skos_concepts_by_id)
          forms             = index_forms(graph, submission)
          senses_by_id, senses               = index_senses(graph, submission, concepts_by_id)
          entries_by_id, entries             = index_entries(graph, submission, forms, senses_by_id, concepts_by_id, signed_forms_by_id)

          link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)
          generate_mapping_triples(entries, submission)

          {
            entries: entries, senses: senses_by_id, concepts: concepts, forms: forms,
            definitions: definitions, notes: notes, usage_examples: usage_examples,
            usages: usages, signed_forms: signed_forms_by_id, videos: videos_by_id,
            references: references, activities: activities, agents: agents,
            skos_concepts: skos_concepts
          }
        ensure
          # Free the in-memory indices after parse
          @type_index = nil
          @prop_index = nil
        end

        # ---------------------------------------------------------------------------
        # In-memory graph index builders
        # ---------------------------------------------------------------------------

        # Build {type_uri_string => Set<subject>}  from a single rdf:type scan
        def build_type_index(graph)
          idx = Hash.new { |h, k| h[k] = Set.new }
          type_preds = Set.new(RDF_TYPE.map(&:to_s)) << RDF.type.to_s
          graph.each_statement do |st|
            idx[st.object.to_s] << st.subject if type_preds.include?(st.predicate.to_s)
          end
          idx
        end

        # Build {subject_string => {predicate_string => [objects]}}  from one full scan
        def build_prop_index(graph)
          idx = Hash.new { |h, k| h[k] = Hash.new { |h2, k2| h2[k2] = [] } }
          type_preds = Set.new(RDF_TYPE.map(&:to_s)) << RDF.type.to_s
          graph.each_statement do |st|
            next if type_preds.include?(st.predicate.to_s)
            idx[st.subject.to_s][st.predicate.to_s] << st.object
          end
          idx
        end

        # Return subjects for a given RDF type (uses @type_index)
        def type_subjects(type_uri)
          @type_index ? @type_index[conv_uri(type_uri).to_s] : subjects_of_type_slow(nil, type_uri)
        end

        # ---------------------------------------------------------------------------
        # Fast O(1) property lookups using @prop_index
        # ---------------------------------------------------------------------------

        def idx_values(subject, predicate)
          return nil unless @prop_index
          vals = @prop_index[subject.to_s][conv_uri(predicate).to_s]
          return nil if vals.empty?
          vals.length == 1 ? vals.first : vals
        end

        def idx_ref_values(subject, predicate)
          return nil unless @prop_index
          vals = @prop_index[subject.to_s][conv_uri(predicate).to_s].select { |o| o.is_a?(RDF::URI) }
          vals.empty? ? nil : vals
        end

        # ---------------------------------------------------------------------------
        # Bulk save helpers
        # ---------------------------------------------------------------------------

        # Validate and persist a collection of Goo objects in a single batch.
        #
        # Strategy:
        #   1. Run field-level validation on each object WITHOUT calling exist?
        #      (which does a SPARQL round-trip per object). We know these are new
        #      objects from a fresh parse so duplicates are impossible.
        #   2. Call Goo::SPARQL::Triples.model_update_triples on each valid object
        #      to obtain an RDF::Graph of the triples to insert — this is the same
        #      code path that save() uses internally, minus the network call.
        #   3. Accumulate all triples into one RDF::Graph and flush to the triple
        #      store in SYNC_BATCH_SIZE batches via a single code path that works
        #      for both 4store and AllegroGraph.
        #   4. Mark all objects @persistent = true so downstream code can call
        #      .id on them safely.
        def bulk_save(objects, submission, label)
          return if objects.empty?

          valid_objects  = []
          combined_graph = RDF::Graph.new

          objects.each do |obj|
            # Ensure modified_attributes is populated (needed by model_update_triples)
            obj.instance_variable_set(:@persistent, false)

            # Apply defaults the same way save() does, so model_update_triples
            # picks them up via modified_attributes
            obj.class.attributes_with_defaults.each do |attr|
              if obj.instance_variable_get("@#{attr}").nil?
                obj.send("#{attr}=", obj.class.default(attr).call(obj))
              end
            end

            # Field-level validation only — no exist? SPARQL call
            validation_errors = {}
            obj.class.attributes.each do |attr|
              inst_value = obj.instance_variable_get("@#{attr}")
              errs = Goo::Validators::Enforce.enforce(obj, attr, inst_value)
              validation_errors[attr] = errs unless errs.nil?
            end

            unless validation_errors.empty?
              warn("[OntoLex] #{label} #{obj.id} invalid, skipping: #{validation_errors}")
              next
            end

            graph_insert, _graph_delete = Goo::SPARQL::Triples.model_update_triples(obj)
            graph_insert.each_statement { |st| combined_graph << st } if graph_insert

            valid_objects << obj
          end

          return if valid_objects.empty?

          upload_graph(combined_graph, submission)

          # Mark persistent so downstream .id calls and bring? checks work
          valid_objects.each do |obj|
            obj.instance_variable_set(:@persistent, true)
            obj.instance_variable_set(:@modified_attributes, Set.new)
            obj.instance_variable_set(:@loaded_attributes,
              Set.new(obj.class.attributes).union(obj.loaded_attributes))
          end

          warn("[OntoLex] Bulk saved #{valid_objects.size} #{label} objects " \
               "(#{combined_graph.count} triples)")
        end

        # Upload an RDF::Graph to the submission named graph.
        # Uses INSERT DATA for both backends — no regex parsing, no format mismatch.
        def upload_graph(graph, submission)
          return if graph.empty?

          statements = graph.to_a
          statements.each_slice(SYNC_BATCH_SIZE) do |batch|
            nt_body = batch.map(&:to_ntriples).join("\n")
            sparql_update_client.update(
              "INSERT DATA { GRAPH <#{submission.id}> {\n#{nt_body}\n} }"
            )
          end
        end

        # ---------------------------------------------------------------------------
        # Graph loading
        # ---------------------------------------------------------------------------

        def load_graph(rdf_source)
          warn("[OntoLex] Loading RDF from source: #{rdf_source}")
          ext = rdf_source.is_a?(String) ? File.extname(rdf_source).downcase : nil
          graph = RDF::Graph.new

          raise ArgumentError, "Source must be a file path: #{rdf_source}" unless File.file?(rdf_source)

          content = File.read(rdf_source)
          warn("[OntoLex] Read #{content.bytesize} bytes")

          case ext
          when '.nt', '.ntriples'
            RDF::NTriples::Reader.new(content) { |r| r.each_statement { |st| graph << st } }
          when '.ttl', '.turtle'
            nt_content = `rapper -i turtle -o ntriples "#{rdf_source}" 2>/dev/null`
            if $?.success? && !nt_content.empty?
              warn("[OntoLex] Converted TTL→NTriples: #{nt_content.lines.count} lines")
              RDF::NTriples::Reader.new(nt_content) { |r| r.each_statement { |st| graph << st } }
            else
              raise StandardError, "Unable to parse TTL file via rapper: #{rdf_source}"
            end
          else
            raise StandardError, "Unsupported format: #{ext}. Use .nt or .ttl"
          end

          warn("[OntoLex] Loaded #{graph.count} statements")
          graph
        end

        # ---------------------------------------------------------------------------
        # Backend detection & client helpers
        # ---------------------------------------------------------------------------

        def fourstore_backend?
          return @_fourstore_backend unless @_fourstore_backend.nil?
          client   = Goo.sparql_data_client
          endpoint = client.respond_to?(:url) ? client.url.to_s :
                     (client.respond_to?(:instance_variable_get) ? client.instance_variable_get(:@url).to_s : '')
          @_fourstore_backend = endpoint.include?('4store') ||
                                client.class.name.to_s.downcase.include?('4store') ||
                                begin
                                  Goo.sparql_query_client(:main).query('SELECT * WHERE { ?s ?p ?o } LIMIT 0')
                                  false
                                rescue SPARQL::Client::ServerError => err
                                  err.message.to_s.include?('4store')
                                rescue StandardError
                                  false
                                end
          @_fourstore_backend
        end

        def sparql_update_client
          Goo.sparql_update_client
        end

        # ---------------------------------------------------------------------------
        # Submission graph sync
        # ---------------------------------------------------------------------------

        def sync_submission_graph(graph, submission)
          warn("[OntoLex] Syncing source graph → submission graph #{submission.id}")
          Goo.sparql_data_client.delete_graph(submission.id)

          if fourstore_backend?
            warn("[OntoLex] 4store: loading #{graph.count} triples via SPARQL UPDATE batches")
            statements = graph.to_a
            total_batches = (statements.size.to_f / SYNC_BATCH_SIZE).ceil
            statements.each_slice(SYNC_BATCH_SIZE).with_index(1) do |batch, idx|
              nt_lines = batch.map(&:to_ntriples).join("\n")
              sparql_update_client.update(
                "INSERT DATA { GRAPH <#{submission.id}> {\n#{nt_lines}\n} }"
              )
              warn("[OntoLex] sync batch #{idx}/#{total_batches}") if (idx % 10).zero? || idx == total_batches
            end
          else
            tmp = Tempfile.new(['ontolex_source_graph', '.nt'])
            begin
              tmp.write(graph.dump(:ntriples))
              tmp.flush
              Goo.sparql_data_client.put_triples(submission.id, tmp.path, 'application/n-triples')
            ensure
              tmp.close
              tmp.unlink
            end
          end

          warn("[OntoLex] Submission graph synchronized (#{graph.count} triples)")
        end

        # ---------------------------------------------------------------------------
        # Auxiliary entity indexers  (Definition, Note, UsageExample, Usage, Video,
        #                             SignedForm, Reference, Activity, Agent)
        # All follow the same pattern: build objects → bulk_save → return collection
        # ---------------------------------------------------------------------------

        def index_definitions(graph, submission)
          warn('[OntoLex] Indexing Definitions...')
          objs = type_subjects(TERMLEX.Definition).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'definition')
            obj = LinkedData::Models::OntoLex::Definition.new(id: id)
            obj.submission = submission
            obj.language   = idx_values(orig_id, DCTERMS.language)
            obj.value      = idx_values(orig_id, RDF_NS.value)
            obj.label      = idx_values(orig_id, RDF::RDFS.label)
            derived        = idx_ref_values(orig_id, PROV.wasDerivedFrom)
            obj.wasDerivedFrom = derived if derived
            obj
          end
          bulk_save(objs, submission, 'Definition')
          warn("[OntoLex] Indexed #{objs.size} definitions")
          objs
        end

        def index_notes(graph, submission)
          warn('[OntoLex] Indexing Notes...')
          objs = type_subjects(TERMLEX.Note).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'note')
            obj = LinkedData::Models::OntoLex::Note.new(id: id)
            obj.submission = submission
            obj.language   = idx_values(orig_id, DCTERMS.language)
            obj.value      = idx_values(orig_id, RDF::RDFS.label)
            derived        = idx_ref_values(orig_id, PROV.wasDerivedFrom)
            obj.wasDerivedFrom = derived if derived
            obj
          end
          bulk_save(objs, submission, 'Note')
          warn("[OntoLex] Indexed #{objs.size} notes")
          objs
        end

        def index_usage_examples(graph, submission)
          warn('[OntoLex] Indexing UsageExamples...')
          objs = type_subjects(LEXICOG.UsageExample).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'usage_example')
            obj = LinkedData::Models::OntoLex::UsageExample.new(id: id)
            obj.submission = submission
            obj.language   = idx_values(orig_id, DCTERMS.language)
            obj.value      = idx_values(orig_id, RDF_NS.value)
            obj.source     = idx_values(orig_id, DCTERMS.source)
            obj
          end
          bulk_save(objs, submission, 'UsageExample')
          warn("[OntoLex] Indexed #{objs.size} usage examples")
          objs
        end

        def index_usages(graph, submission)
          warn('[OntoLex] Indexing Usages...')
          objs = type_subjects(TERMLEX.Usage).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'usage')
            obj = LinkedData::Models::OntoLex::Usage.new(id: id)
            obj.submission = submission
            obj.language   = idx_values(orig_id, DCTERMS.language)
            obj.value      = idx_values(orig_id, RDF_NS.value)
            src = idx_ref_values(orig_id, DCTERMS.source)
            obj.source = src if src
            obj
          end
          bulk_save(objs, submission, 'Usage')
          warn("[OntoLex] Indexed #{objs.size} usages")
          objs
        end

        def index_videos(graph, submission)
          warn('[OntoLex] Indexing Videos...')
          videos = {}
          objs = type_subjects(ETV.Video).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'video')
            obj = LinkedData::Models::OntoLex::Video.new(id: id)
            obj.submission = submission
            obj.url        = idx_values(orig_id, ETV.url)
            videos[orig_id] = obj
            obj
          end
          bulk_save(objs, submission, 'Video')
          warn("[OntoLex] Indexed #{videos.size} videos")
          videos
        end

        def index_signed_forms(graph, submission, videos_by_id)
          warn('[OntoLex] Indexing SignedForms...')
          signed_forms = {}
          objs = []
          type_subjects(ETV.signedForm).each do |orig_id|
            id  = skolemize_id(orig_id, submission, 'signed_form')
            obj = LinkedData::Models::OntoLex::SignedForm.new(id: id)
            obj.submission = submission
            # Link to first known Video
            video_ref = (@prop_index[orig_id.to_s][conv_uri(ETV.signedRep).to_s] || []).first
            if video_ref && videos_by_id[video_ref]
              obj.signedRep = videos_by_id[video_ref]
            end
            signed_forms[orig_id] = obj
            objs << obj
          end
          bulk_save(objs, submission, 'SignedForm')
          warn("[OntoLex] Indexed #{signed_forms.size} signed forms")
          signed_forms
        end

        def index_references(graph, submission)
          warn('[OntoLex] Indexing References...')
          objs = type_subjects(PROV.Entity).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'reference')
            obj = LinkedData::Models::OntoLex::Reference.new(id: id)
            obj.submission = submission
            obj.label      = idx_values(orig_id, RDF::RDFS.label)
            obj.value      = idx_values(orig_id, RDF_NS.value)
            deriv = idx_ref_values(orig_id, PROV.hasDerivation)
            obj.hasDerivation = deriv if deriv
            obj
          end
          bulk_save(objs, submission, 'Reference')
          warn("[OntoLex] Indexed #{objs.size} references")
          objs
        end

        def index_activities(graph, submission)
          warn('[OntoLex] Indexing Activities...')
          objs = type_subjects(PROV.Activity).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'activity')
            obj = LinkedData::Models::OntoLex::Activity.new(id: id)
            obj.submission  = submission
            obj.label       = idx_values(orig_id, RDF::RDFS.label)
            obj.endedAtTime = idx_values(orig_id, PROV.endedAtTime)
            obj.hasDerivation   = idx_values(orig_id, PROV.hasDerivation)
            infl = idx_ref_values(orig_id, PROV.influenced)
            obj.influenced = infl if infl
            obj
          end
          bulk_save(objs, submission, 'Activity')
          warn("[OntoLex] Indexed #{objs.size} activities")
          objs
        end

        def index_agents(graph, submission)
          warn('[OntoLex] Indexing Agents...')
          objs = type_subjects(PROV.Agent).map do |orig_id|
            id  = skolemize_id(orig_id, submission, 'agent')
            obj = LinkedData::Models::OntoLex::Agent.new(id: id)
            obj.submission = submission
            obj.name       = idx_values(orig_id, FOAF.name)
            obj.mbox       = idx_values(orig_id, FOAF.mbox)
            assoc = idx_ref_values(orig_id, PROV.wasAssociatedFor)
            obj.wasAssociatedFor = assoc if assoc
            obj
          end
          bulk_save(objs, submission, 'Agent')
          warn("[OntoLex] Indexed #{objs.size} agents")
          objs
        end

        # ---------------------------------------------------------------------------
        # SKOS Concepts (stored as LinkedData::Models::Class)
        # ---------------------------------------------------------------------------

        def index_skos_concepts(graph, submission)
          warn('[OntoLex] Indexing SKOS Concepts...')
          skos_ids   = type_subjects(SKOS.Concept)
          lexical_ids = type_subjects(ONTOLEX.LexicalConcept)
          pure_skos_ids = skos_ids - lexical_ids

          skos_concepts_by_id = {}
          objs = []

          pure_skos_ids.each do |orig_id|
            sc = LinkedData::Models::Class.new(id: orig_id)
            sc.submission = submission
            sc.prefLabel  = idx_values(orig_id, SKOS.prefLabel)

            broader = idx_values(orig_id, SKOS.broader)
            if broader
              broader_array = Array(broader)
              sc.parents = broader_array.map { |uri| LinkedData::Models::Class.new(id: uri) }
            end

            in_scheme = idx_values(orig_id, SKOS.inScheme)
            sc.inScheme = Array(in_scheme) if in_scheme

            skos_concepts_by_id[orig_id] = sc
            objs << sc
          end

          bulk_save(objs, submission, 'SKOSConcept')

          # isTopConceptOf — batch all triples together
          top_concept_pred = RDF::URI('http://www.w3.org/2004/02/skos/core#isTopConceptOf')
          top_triples = []
          pure_skos_ids.each do |orig_id|
            tc = idx_values(orig_id, SKOS.isTopConceptOf)
            next unless tc
            Array(tc).each { |t| top_triples << "<#{orig_id}> <#{top_concept_pred}> <#{t}> ." }
          end
          unless top_triples.empty?
            top_triples.each_slice(SYNC_BATCH_SIZE) do |batch|
              sparql_update_client.update(
                "INSERT DATA { GRAPH <#{submission.id}> { #{batch.join(' ')} } }"
              )
            end
          end

          warn("[OntoLex] Indexed #{objs.size} SKOS concepts")
          [skos_concepts_by_id, objs]
        end

        # ---------------------------------------------------------------------------
        # LexicalConcepts
        # ---------------------------------------------------------------------------

        def index_concepts(graph, submission, skos_concepts_by_id = {})
          warn('[OntoLex] Indexing LexicalConcepts...')
          concepts_by_id = {}
          objs = []

          type_subjects(ONTOLEX.LexicalConcept).each do |orig_id|
            id = skolemize_id(orig_id, submission, 'concept')
            lc = LinkedData::Models::OntoLex::LexicalConcept.new(id: id)
            lc.submission = submission

            defs = idx_values(orig_id, SKOS.definition)
            lc.definition = Array(defs) if defs

            notes = idx_values(orig_id, SKOS.note)
            lc.note = Array(notes) if notes

            schemes = idx_values(orig_id, SKOS.inScheme)
            lc.inScheme = schemes.is_a?(Array) ? schemes.first : schemes if schemes

            lc.source = idx_values(orig_id, DCTERMS.source)

            subj_uri = idx_values(orig_id, DCTERMS.subject)
            if subj_uri
              subj_uri = subj_uri.is_a?(Array) ? subj_uri.first : subj_uri
              lc.subject = skos_concepts_by_id[subj_uri] if skos_concepts_by_id[subj_uri]
            end

            [
              [:broader,        SKOS.broader],
              [:narrower,       SKOS.narrower],
              [:related,        SKOS.related],
              [:mappingRelation, SKOS.mappingRelation],
              [:broadMatch,     SKOS.broadMatch],
              [:closeMatch,     SKOS.closeMatch],
              [:exactMatch,     SKOS.exactMatch],
              [:narrowMatch,    SKOS.narrowMatch],
              [:relatedMatch,   SKOS.relatedMatch],
              [:differentFrom,  OWL.differentFrom],
              [:antonym,        LEXINFO.antonym],
              [:isPartOf,       DCTERMS.isPartOf],
              [:hasPart,        DCTERMS.hasPart],
              [:capital,        DBO.capital],
              [:currency,       DBO.currency],
              [:causedBy,       DBO.causedBy],
              [:precedesInTime, RICO.precedesInTime],
              [:followsInTime,  RICO.followsInTime],
              [:hasLocation,    DUL.hasLocation],
            ].each do |attr, pred|
              vals = idx_ref_values(orig_id, pred)
              lc.send("#{attr}=", vals) if vals && !vals.empty?
            end

            concepts_by_id[orig_id] = lc
            objs << lc
          end

          bulk_save(objs, submission, 'LexicalConcept')
          warn("[OntoLex] Indexed #{objs.size} lexical concepts")
          [concepts_by_id, objs]
        end

        # ---------------------------------------------------------------------------
        # Forms
        # ---------------------------------------------------------------------------

        def index_forms(graph, submission)
          warn('[OntoLex] Indexing Forms...')
          forms = {}
          objs  = []

          type_subjects(ONTOLEX.Form).each do |orig_id|
            id = skolemize_id(orig_id, submission, 'form')
            f  = LinkedData::Models::OntoLex::Form.new(id: id)
            f.submission = submission

            wrep_vals = @prop_index[orig_id.to_s][conv_uri(ONTOLEX.writtenRep).to_s]
            if wrep_vals && !wrep_vals.empty?
              first = wrep_vals.first
              f.writtenRep = first.respond_to?(:value) ? first.value : first.to_s
              lang = wrep_vals.map { |v| v.respond_to?(:language) ? v.language.to_s : nil }.compact.first
              f.language = lang if lang && !lang.empty?
            end

            f.gender     = idx_values(orig_id, LEXINFO.gender)
            f.number     = idx_values(orig_id, LEXINFO.number)
            f.signedForm = idx_values(orig_id, ETV.signedForm)

            forms[orig_id] = f
            objs << f
          end

          bulk_save(objs, submission, 'Form')
          warn("[OntoLex] Indexed #{forms.size} forms")
          forms
        end

        # ---------------------------------------------------------------------------
        # LexicalSenses
        # ---------------------------------------------------------------------------

        def index_senses(graph, submission, concepts_by_id)
          warn('[OntoLex] Indexing LexicalSenses...')
          senses = {}
          objs   = []

          type_subjects(ONTOLEX.LexicalSense).each do |orig_id|
            id = skolemize_id(orig_id, submission, 'sense')
            s  = LinkedData::Models::OntoLex::LexicalSense.new(id: id)
            s.submission = submission

            s.definition           = idx_values(orig_id, DCTERMS.definition)
            s.example              = idx_values(orig_id, DCTERMS.example)
            s.reference            = idx_values(orig_id, ONTOLEX.reference)
            s.synonym              = idx_ref_values(orig_id, LEXINFO.synonym)
            s.translation          = idx_ref_values(orig_id, VARTRANS.translation)
            s.normativeAuthorization = idx_values(orig_id, LEXINFO.normativeAuthorization)
            s.termType             = idx_values(orig_id, LEXINFO.termType)
            s.reliabilityCode      = idx_values(orig_id, TERMLEX.reliabilityCode)

            ue = idx_ref_values(orig_id, LEXICOG.usageExample)
            s.usageExample = ue if ue

            usage = idx_ref_values(orig_id, TERMLEX.usage)
            s.usage = usage if usage

            is_sense_of = (@prop_index[orig_id.to_s][conv_uri(ONTOLEX.isSenseOf).to_s] || []).first
            s.isSenseOf = is_sense_of if is_sense_of

            lex_concept_uris = @prop_index[orig_id.to_s][conv_uri(ONTOLEX.isLexicalizedSenseOf).to_s] || []
            lex_concept_uris.each do |uri|
              c = concepts_by_id[uri]
              s.lexicalConcept = c if c
            end

            senses[orig_id] = s
            objs << s
          end

          bulk_save(objs, submission, 'LexicalSense')
          warn("[OntoLex] Indexed #{senses.size} senses")
          [senses, objs]
        end

        # ---------------------------------------------------------------------------
        # LexicalEntries
        # ---------------------------------------------------------------------------

        def index_entries(graph, submission, forms_by_id, senses_by_id, concepts_by_id, signed_forms_by_id = {})
          warn('[OntoLex] Indexing LexicalEntries...')
          entries       = []
          entries_by_id = {}
          # Accumulate cross-reference triples (form, sense, signedForm links)
          # for a single batch INSERT at the end of this phase
          xref_triples  = []

          form_pred        = RDF::URI('http://www.w3.org/ns/lemon/ontolex#form')
          sense_pred       = RDF::URI('http://www.w3.org/ns/lemon/ontolex#sense')
          signed_form_pred = RDF::URI('https://w3id.org/def/easytv#signedForm')

          type_subjects(ONTOLEX.LexicalEntry).each do |orig_id|
            id = skolemize_id(orig_id, submission, 'entry')
            e  = LinkedData::Models::OntoLex::LexicalEntry.new(id: id)
            e.submission = submission

            e.lemma        = idx_values(orig_id, ONTOLEX.canonicalForm)
            e.language     = idx_values(orig_id, DCTERMS.language)
            e.partOfSpeech = idx_values(orig_id, LEXINFO.partOfSpeech)
            e.termType     = idx_values(orig_id, LEXINFO.termType)
            e.casNumber    = idx_values(orig_id, DBO.casNumber)
            e.code         = idx_values(orig_id, DBO.code)

            valency = idx_ref_values(orig_id, OLIA.hasValency)
            e.hasValency = valency if valency

            # SignedForms
            sf_list = (@prop_index[orig_id.to_s][conv_uri(ETV.signedForm).to_s] || [])
                        .map { |ref| signed_forms_by_id[ref] }.compact
            e.signedForm = sf_list unless sf_list.empty?

            derived = idx_ref_values(orig_id, PROV.wasDerivedFrom)
            e.wasDerivedFrom = derived if derived

            influenced = idx_ref_values(orig_id, PROV.wasInfluencedBy)
            e.wasInfluencedBy = influenced if influenced

            # Forms
            form_uris = [ONTOLEX.canonicalForm, ONTOLEX.otherForm, ONTOLEX.lexicalForm].flat_map do |pf|
              @prop_index[orig_id.to_s][conv_uri(pf).to_s] || []
            end
            forms = form_uris.map { |uri| forms_by_id[uri] }.compact
            e.form = forms unless forms.empty?

            # Senses
            sense_uris = @prop_index[orig_id.to_s][conv_uri(ONTOLEX.sense).to_s] || []
            linked_senses = sense_uris.map { |uri| senses_by_id[uri] }.compact
            e.sense = linked_senses unless linked_senses.empty?

            # Evokes
            evoked_uri = (@prop_index[orig_id.to_s][conv_uri(ONTOLEX.evokes).to_s] || []).first
            e.evokes = concepts_by_id[evoked_uri] if evoked_uri && concepts_by_id[evoked_uri]

            entries_by_id[orig_id] = e
            entries << e

            # Collect cross-reference triples to batch later (after bulk_save sets .id)
            # We store closures because e.id may change if Goo generates it lazily
            forms.each        { |f|  xref_triples << -> { "<#{e.id}> <#{form_pred}> <#{f.id}> ." } }
            linked_senses.each { |s| xref_triples << -> { "<#{e.id}> <#{sense_pred}> <#{s.id}> ." } }
            sf_list.each       { |sf| xref_triples << -> { "<#{e.id}> <#{signed_form_pred}> <#{sf.id}> ." } }
          end

          bulk_save(entries, submission, 'LexicalEntry')

          # Now that all entries are persistent and have stable IDs, flush xref triples
          unless xref_triples.empty?
            resolved = xref_triples.map(&:call)
            resolved.each_slice(SYNC_BATCH_SIZE) do |batch|
              begin
                sparql_update_client.update(
                  "INSERT DATA { GRAPH <#{submission.id}> { #{batch.join(' ')} } }"
                )
              rescue StandardError => e
                warn("[OntoLex] Failed to insert entry xref batch: #{e.message}")
                # Fallback: one by one
                batch.each do |triple|
                  begin
                    sparql_update_client.update(
                      "INSERT DATA { GRAPH <#{submission.id}> { #{triple} } }"
                    )
                  rescue StandardError => single_err
                    warn("[OntoLex] Failed to insert triple '#{triple}': #{single_err.message}")
                  end
                end
              end
            end
            warn("[OntoLex] Inserted #{resolved.size} entry cross-reference triples")
          end

          warn("[OntoLex] Indexed #{entries.size} lexical entries")
          [entries_by_id, entries]
        end

        # ---------------------------------------------------------------------------
        # Second pass: link cross-references for concepts
        # ---------------------------------------------------------------------------

        def link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)
          warn('[OntoLex] Linking cross-references (second pass)...')

          isEvokedBy_pred      = RDF::URI('http://www.w3.org/ns/lemon/ontolex#isEvokedBy')
          lexSense_pred        = RDF::URI('http://www.w3.org/ns/lemon/ontolex#lexicalizedSense')
          all_triples          = []

          concepts_by_id.each do |orig_id, concept|
            evoked_by = idx_ref_values(orig_id, ONTOLEX.isEvokedBy)
            if evoked_by
              evoked_entries = evoked_by.map { |uri| entries_by_id[uri] }.compact
              concept.isEvokedBy = evoked_entries unless evoked_entries.empty?
            end

            lex_senses = idx_ref_values(orig_id, ONTOLEX.lexicalizedSense)
            if lex_senses
              sense_objs = lex_senses.map { |uri| senses_by_id[uri] }.compact
              concept.lexicalizedSense = sense_objs unless sense_objs.empty?
            end

            # Validate without exist? check (objects are already persistent)
            concept.instance_variable_set(:@persistent, true)
            validation_errors = {}
            concept.class.attributes.each do |attr|
              inst_value = concept.instance_variable_get("@#{attr}")
              attr_errors = Goo::Validators::Enforce.enforce(concept, attr, inst_value)
              validation_errors[attr] = attr_errors unless attr_errors.nil?
            end

            if validation_errors.empty?
              Array(concept.isEvokedBy).each do |entry|
                all_triples << "<#{concept.id}> <#{isEvokedBy_pred}> <#{entry.id}> ."
              end
              Array(concept.lexicalizedSense).each do |sense|
                all_triples << "<#{concept.id}> <#{lexSense_pred}> <#{sense.id}> ."
              end
            else
              warn("[OntoLex] Concept #{concept.id} invalid during xref pass: #{validation_errors}")
            end
          end

          unless all_triples.empty?
            all_triples.each_slice(SYNC_BATCH_SIZE) do |batch|
              begin
                sparql_update_client.update(
                  "INSERT DATA { GRAPH <#{submission.id}> { #{batch.join(' ')} } }"
                )
              rescue StandardError => e
                warn("[OntoLex] Concept xref batch failed: #{e.message}")
                batch.each do |triple|
                  begin
                    sparql_update_client.update(
                      "INSERT DATA { GRAPH <#{submission.id}> { #{triple} } }"
                    )
                  rescue StandardError => se
                    warn("[OntoLex] Failed triple: #{triple}: #{se.message}")
                  end
                end
              end
            end
            warn("[OntoLex] Inserted #{all_triples.size} concept cross-reference triples")
          end

          warn('[OntoLex] Second pass completed')
        end

        # ---------------------------------------------------------------------------
        # Mapping triples (LOOM + SAME_URI)
        # ---------------------------------------------------------------------------

        def generate_mapping_triples(entries, submission)
          warn('[OntoLex] Generating LOOM/SAME_URI mapping triples...')

          submission.bring(:ontology) if submission.respond_to?(:bring) && submission.bring?(:ontology)
          submission.ontology.bring(:viewOf) if submission.ontology.respond_to?(:bring) && submission.ontology.bring?(:viewOf)

          if submission.ontology.viewOf
            warn('[OntoLex] Skipping mapping generation for view ontology')
            return
          end

          mapping_loom_pred     = Goo.vocabulary(:metadata_def)[:mappingLoom]
          mapping_same_uri_pred = Goo.vocabulary(:metadata_def)[:mappingSameURI]

          # Clear existing mapping triples
          [mapping_loom_pred, mapping_same_uri_pred].each do |pred|
            begin
              sparql_update_client.update(
                "DELETE WHERE { GRAPH <#{submission.id}> { ?s <#{pred}> ?o . } }"
              )
            rescue StandardError => e
              warn("[OntoLex] Failed to clear mapping triples for #{pred}: #{e.message}")
            end
          end

          query = <<-SPARQL
SELECT DISTINCT ?entry (SAMPLE(?rep) as ?label)
WHERE {
  GRAPH <#{submission.id}> {
    ?entry a <http://www.w3.org/ns/lemon/ontolex#LexicalEntry> .
    ?entry <http://www.w3.org/ns/lemon/ontolex#form> ?form .
    ?form <http://www.w3.org/ns/lemon/ontolex#writtenRep> ?rep .
  }
}
GROUP BY ?entry
          SPARQL

          solutions = Goo.sparql_query_client(:main).query(query)
          warn("[OntoLex] #{solutions.length} entries found for LOOM matching")

          mapping_triples = []
          solutions.each do |sol|
            entry_id = sol[:entry].to_s
            label    = sol[:label].to_s
            loom_label = loom_transform_literal(label)
            mapping_triples << "<#{entry_id}> <#{mapping_loom_pred}> \"#{loom_label}\" ." if loom_label.length > 2
            mapping_triples << "<#{entry_id}> <#{mapping_same_uri_pred}> <#{entry_id}> ."
          end

          if mapping_triples.any?
            warn("[OntoLex] Inserting #{mapping_triples.size} mapping triples")
            mapping_triples.each_slice(MAPPING_BATCH_SIZE) do |batch|
              triples_str = batch.join("\n")
              Goo.sparql_data_client.append_triples(
                submission.id, triples_str, 'application/x-turtle'
              )
            end
            regenerate_mapping_counts(submission)
          else
            warn('[OntoLex] No mapping triples generated')
          end
        end

        def regenerate_mapping_counts(submission)
          acronym = submission.ontology.acronym
          warn("[OntoLex] Regenerating mapping counts for #{acronym}...")
          begin
            require 'logger'
            LinkedData::Mappings.create_mapping_counts(Logger.new(STDERR), [acronym])
            warn("[OntoLex] Mapping counts regenerated for #{acronym}")
          rescue StandardError => e
            warn("[OntoLex] Failed to regenerate mapping counts: #{e.message}")
          end
        end

        def loom_transform_literal(lit)
          lit.to_s.chars.select { |c|
            (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
          }.map(&:downcase).join
        end

        # ---------------------------------------------------------------------------
        # Legacy helpers (kept for compatibility; fast path uses idx_* above)
        # ---------------------------------------------------------------------------

        def subjects_of_type(graph, type_uri)
          return type_subjects(type_uri) if @type_index
          subjects_of_type_slow(graph, type_uri)
        end

        def subjects_of_type_slow(graph, type_uri)
          target = conv_uri(type_uri).to_s
          ids = Set.new
          graph&.query(predicate: RDF.type)&.each do |st|
            ids << st.subject if st.object.to_s == target
          end
          ids
        end

        def values_for(graph, subject, predicate)
          return idx_values(subject, predicate) if @prop_index
          pred = conv_uri(predicate)
          vals = graph.query(subject: subject, predicate: pred).map(&:object)
          return nil if vals.empty?
          vals.length == 1 ? vals.first : vals
        end

        def ref_values_for(graph, subject, predicate)
          return idx_ref_values(subject, predicate) if @prop_index
          pred = conv_uri(predicate)
          vals = graph.query(subject: subject, predicate: pred).map(&:object).select { |o| o.is_a?(RDF::URI) }
          vals.empty? ? nil : vals
        end

        def conv_uri(term)
          term.respond_to?(:to_uri) ? term.to_uri : term
        end

        def skolemize_id(term, submission, kind)
          return term if term.is_a?(RDF::URI)
          node_id = term.to_s.gsub(/^_:/, '')
          prefix  = LinkedData.settings.id_url_prefix || 'http://example.org'
          RDF::URI.new("#{prefix}/.well-known/genid/ontolex/#{submission&.submissionId}/#{kind}/#{CGI.escape(node_id)}")
        end
      end
    end
  end
end