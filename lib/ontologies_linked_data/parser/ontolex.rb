require 'rdf'
require 'rdf/turtle'
require 'rdf/ntriples'
require 'addressable/uri'
require 'cgi'
require 'set'

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

        # The output will be a Turtle file in the same directory
        output_path = File.join(File.dirname(@file_path), 'ontolex_triples.ttl')

        # Parse the OntoLex file and save to triple store
        OntoLex.parse(@file_path, @submission)

        @logger&.info('OntoLex parsing completed')

        # Return the output path for the RDF generator to use
        # Since OntoLex.parse saves directly to triple store, we return the original file
        # The RDF generator will skip the upload step for OntoLex
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

      class << self
        def parse(rdf_source, submission, options = {})
          raise ArgumentError, 'submission is required' unless submission

          # Ensure submission is properly loaded with all necessary attributes
          submission.bring(:ontology) if submission.respond_to?(:bring) && !submission.ontology

          graph = load_graph(rdf_source)
          warn("[OntoLex] Graph statements: #{graph.count}")
          begin
            types = graph.query(predicate: RDF.type).objects.uniq.map(&:to_s)
            warn("[OntoLex] RDF.type objects: #{types.join(', ')}")
          rescue StandardError
          end
          warn("[OntoLex] SKOS Concept subjects: #{subjects_of_type(graph, SKOS.Concept).size}")
          warn("[OntoLex] LexicalConcept subjects: #{subjects_of_type(graph, ONTOLEX.LexicalConcept).size}")
          warn("[OntoLex] LexicalEntry subjects: #{subjects_of_type(graph, ONTOLEX.LexicalEntry).size}")
          warn("[OntoLex] LexicalSense subjects: #{subjects_of_type(graph, ONTOLEX.LexicalSense).size}")
          warn("[OntoLex] Form subjects: #{subjects_of_type(graph, ONTOLEX.Form).size}")

          # Parse auxiliary entities first so they exist when main entities reference them
          references = index_references(graph, submission)
          activities = index_activities(graph, submission)
          agents = index_agents(graph, submission)
          definitions = index_definitions(graph, submission)
          notes = index_notes(graph, submission)
          usage_examples = index_usage_examples(graph, submission)
          usages = index_usages(graph, submission)
          videos_by_id = index_videos(graph, submission)
          signed_forms_by_id = index_signed_forms(graph, submission, videos_by_id)

          # Parse SKOS Concepts as Class objects (these are subjects for LexicalConcepts)
          skos_concepts_by_id, skos_concepts = index_skos_concepts(graph, submission)

          # Parse OntoLex LexicalConcepts
          concepts_by_id, concepts = index_concepts(graph, submission, skos_concepts_by_id)
          forms = index_forms(graph, submission)
          senses_by_id, senses = index_senses(graph, submission, concepts_by_id)
          entries_by_id, entries = index_entries(graph, submission, forms, senses_by_id, concepts_by_id, signed_forms_by_id)

          # Second pass: link cross-references now that all objects exist
          link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)

          {
            entries: entries,
            senses: senses,
            concepts: concepts,
            forms: forms,
            definitions: definitions,
            notes: notes,
            usage_examples: usage_examples,
            usages: usages,
            signed_forms: signed_forms_by_id,
            videos: videos_by_id,
            references: references,
            activities: activities,
            agents: agents,
            skos_concepts: skos_concepts
          }
        end

        def load_graph(rdf_source)
          warn("[OntoLex] Loading RDF from source: #{rdf_source}")
          ext = rdf_source.is_a?(String) ? File.extname(rdf_source).downcase : nil

          # Use the lower-level approach that works - similar to the original load_graph method
          graph = RDF::Graph.new

          if File.file?(rdf_source)
            content = File.read(rdf_source)
            warn("[OntoLex] Read #{content.bytesize} bytes from file")

            case ext
            when '.nt', '.ntriples'
              warn('[OntoLex] Parsing as N-Triples')
              reader = RDF::NTriples::Reader.new(content)
              reader.each_statement { |st| graph << st }
            when '.ttl', '.turtle'
              warn('[OntoLex] Parsing as Turtle')
              # RDF 1.0.x has a bug with TTL base_uri handling that causes join errors
              # Workaround: Convert TTL to N-Triples using external parser then parse
              # TODO: Update GOO gem to use RDF 3.x which fixes this issue
              success = false

              unless success
                begin
                  nt_content = `rapper -i turtle -o ntriples "#{rdf_source}" 2>/dev/null`
                  if $?.success? && !nt_content.empty?
                    warn("[OntoLex] Converted TTL to N-Triples using rapper: #{nt_content.lines.count} lines")
                    reader = RDF::NTriples::Reader.new(nt_content)
                    reader.each_statement { |st| graph << st }
                    warn('[OntoLex] TTL converted and parsed successfully')
                    success = true
                  end
                rescue StandardError => e
                  warn("[OntoLex] rapper failed: #{e.message}")
                end
              end

              unless success
                warn('[OntoLex] All TTL conversion tools failed')
                raise StandardError.new("Unable to parse TTL file: #{rdf_source}. RDF 1.0.x has TTL parsing issues.")
              end
            else
              warn("[OntoLex] Unknown format: #{ext}")
              raise StandardError.new("Unsupported file format: #{ext}. Only .nt, .ntriples, .ttl, .turtle are supported.")
            end
          else
            warn("[OntoLex] Source is not a file: #{rdf_source}")
            raise ArgumentError.new("Source must be a file path: #{rdf_source}")
          end

          warn("[OntoLex] Loaded #{graph.count} statements")
          graph
        end

        def index_definitions(graph, submission)
          definitions = []
          warn('[OntoLex] Indexing Definition objects...')

          def_ids = subjects_of_type(graph, TERMLEX.Definition)
          warn("[OntoLex] Found #{def_ids.size} Definition subjects")

          def_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'definition')

            defn = LinkedData::Models::OntoLex::Definition.new(id: id)
            defn.submission = submission

            lang = values_for(graph, orig_id, DCTERMS.language)
            defn.language = lang if lang

            value = values_for(graph, orig_id, RDF_NS.value)
            defn.value = value if value

            label = values_for(graph, orig_id, RDF::RDFS.label)
            defn.label = label if label

            derived_from = ref_values_for(graph, orig_id, PROV.wasDerivedFrom)
            defn.wasDerivedFrom = derived_from if derived_from && !derived_from.empty?

            if defn.valid?
              warn("[OntoLex] Saving Definition #{id}")
              defn.save(override_security: true)
              definitions << defn
              warn("[OntoLex] Definition saved successfully: language=#{defn.language}, value_length=#{defn.value&.to_s&.length || 0}")
            else
              warn("[OntoLex] Definition INVALID: #{id}, errors: #{defn.errors}")
            end
          end

          warn("[OntoLex] Indexed #{definitions.size} definitions")
          definitions
        end

        def index_notes(graph, submission)
          notes = []
          warn('[OntoLex] Indexing Note objects...')

          note_ids = subjects_of_type(graph, TERMLEX.Note)
          warn("[OntoLex] Found #{note_ids.size} Note subjects")

          note_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'note')

            note = LinkedData::Models::OntoLex::Note.new(id: id)
            note.submission = submission

            lang = values_for(graph, orig_id, DCTERMS.language)
            note.language = lang if lang

            value = values_for(graph, orig_id, RDF::RDFS.label)
            note.value = value if value

            derived_from = ref_values_for(graph, orig_id, PROV.wasDerivedFrom)
            note.wasDerivedFrom = derived_from if derived_from && !derived_from.empty?

            if note.valid?
              warn("[OntoLex] Saving Note #{id}")
              note.save(override_security: true)
              notes << note
            else
              warn("[OntoLex] Note INVALID: #{id}, errors: #{note.errors}")
            end
          end

          warn("[OntoLex] Indexed #{notes.size} notes")
          notes
        end

        def index_usage_examples(graph, submission)
          examples = []
          warn('[OntoLex] Indexing UsageExample objects...')

          example_ids = subjects_of_type(graph, LEXICOG.UsageExample)
          warn("[OntoLex] Found #{example_ids.size} UsageExample subjects")

          example_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'usage_example')

            example = LinkedData::Models::OntoLex::UsageExample.new(id: id)
            example.submission = submission

            lang = values_for(graph, orig_id, DCTERMS.language)
            example.language = lang if lang

            value = values_for(graph, orig_id, RDF_NS.value)
            example.value = value if value

            source = values_for(graph, orig_id, DCTERMS.source)
            example.source = source if source

            if example.valid?
              warn("[OntoLex] Saving UsageExample #{id}")
              example.save(override_security: true)
              examples << example
            else
              warn("[OntoLex] UsageExample INVALID: #{id}, errors: #{example.errors}")
            end
          end

          warn("[OntoLex] Indexed #{examples.size} usage examples")
          examples
        end

        def index_usages(graph, submission)
          usages = []
          warn('[OntoLex] Indexing Usage objects...')

          usage_ids = subjects_of_type(graph, TERMLEX.Usage)
          warn("[OntoLex] Found #{usage_ids.size} Usage subjects")

          usage_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'usage')

            usage = LinkedData::Models::OntoLex::Usage.new(id: id)
            usage.submission = submission

            lang = values_for(graph, orig_id, DCTERMS.language)
            usage.language = lang if lang

            value = values_for(graph, orig_id, RDF_NS.value)
            usage.value = value if value

            source = ref_values_for(graph, orig_id, DCTERMS.source)
            usage.source = source if source && !source.empty?

            if usage.valid?
              warn("[OntoLex] Saving Usage #{id}")
              usage.save(override_security: true)
              usages << usage
            else
              warn("[OntoLex] Usage INVALID: #{id}, errors: #{usage.errors}")
            end
          end

          warn("[OntoLex] Indexed #{usages.size} usages")
          usages
        end

        def index_signed_forms(graph, submission, videos_by_id)
          signed_forms = {}
          warn('[OntoLex] Indexing SignedForm objects...')

          sf_ids = subjects_of_type(graph, ETV.signedForm)
          warn("[OntoLex] Found #{sf_ids.size} SignedForm subjects")

          sf_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'signed_form')

            sf = LinkedData::Models::OntoLex::SignedForm.new(id: id)
            sf.submission = submission

            # Read signedRep property and link to Video object
            # signedRep is singular (not a list), so we take the first one
            signed_rep_refs = graph.query(subject: orig_id, predicate: conv_uri(ETV.signedRep))
            signed_rep_refs.each do |statement|
              video = videos_by_id[statement.object]
              if video
                sf.signedRep = video  # Assign first video
                warn("[OntoLex] Linked SignedForm #{id} -> Video #{video.id}")
                break  # Only take the first one
              else
                warn("[OntoLex] WARNING: SignedForm #{id} references unknown Video #{statement.object}")
              end
            end

            if sf.valid?
              warn("[OntoLex] Saving SignedForm #{id}")
              sf.save(override_security: true)
              signed_forms[orig_id] = sf
            else
              warn("[OntoLex] SignedForm INVALID: #{id}, errors: #{sf.errors}")
            end
          end

          warn("[OntoLex] Indexed #{signed_forms.size} signed forms")
          signed_forms
        end

        def index_videos(graph, submission)
          videos = {}
          warn('[OntoLex] Indexing Video objects...')

          video_ids = subjects_of_type(graph, ETV.Video)
          warn("[OntoLex] Found #{video_ids.size} Video subjects")

          video_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'video')

            video = LinkedData::Models::OntoLex::Video.new(id: id)
            video.submission = submission

            url = values_for(graph, orig_id, ETV.url)
            video.url = url if url

            if video.valid?
              warn("[OntoLex] Saving Video #{id}")
              video.save(override_security: true)
              videos[orig_id] = video
            else
              warn("[OntoLex] Video INVALID: #{id}, errors: #{video.errors}")
            end
          end

          warn("[OntoLex] Indexed #{videos.size} videos")
          videos
        end

        def index_references(graph, submission)
          references = []
          warn('[OntoLex] Indexing Reference (prov:Entity) objects...')

          ref_ids = subjects_of_type(graph, PROV.Entity)
          warn("[OntoLex] Found #{ref_ids.size} prov:Entity subjects")

          ref_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'reference')

            ref = LinkedData::Models::OntoLex::Reference.new(id: id)
            ref.submission = submission

            label = values_for(graph, orig_id, RDF::RDFS.label)
            ref.label = label if label

            value = values_for(graph, orig_id, RDF_NS.value)
            ref.value = value if value

            has_derivation = ref_values_for(graph, orig_id, PROV.hasDerivation)
            ref.hasDerivation = has_derivation if has_derivation && !has_derivation.empty?

            if ref.valid?
              ref.save(override_security: true)
              references << ref
            else
              warn("[OntoLex] Reference INVALID: #{id}, errors: #{ref.errors}")
            end
          end

          warn("[OntoLex] Indexed #{references.size} references")
          references
        end

        def index_activities(graph, submission)
          activities = []
          warn('[OntoLex] Indexing Activity (prov:Activity) objects...')

          act_ids = subjects_of_type(graph, PROV.Activity)
          warn("[OntoLex] Found #{act_ids.size} prov:Activity subjects")

          act_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'activity')

            act = LinkedData::Models::OntoLex::Activity.new(id: id)
            act.submission = submission

            label = values_for(graph, orig_id, RDF::RDFS.label)
            act.label = label if label

            ended_at = values_for(graph, orig_id, PROV.endedAtTime)
            act.endedAtTime = ended_at if ended_at

            # hasDerivation points to Agent
            has_deriv = values_for(graph, orig_id, PROV.hasDerivation)
            act.hasDerivation = has_deriv if has_deriv

            assoc_with = values_for(graph, orig_id, PROV.wasAssociatedWith)
            act.wasAssociatedWith = assoc_with if assoc_with

            influenced = ref_values_for(graph, orig_id, PROV.influenced)
            act.influenced = influenced if influenced && !influenced.empty?

            if act.valid?
              act.save(override_security: true)
              activities << act
            else
              warn("[OntoLex] Activity INVALID: #{id}, errors: #{act.errors}")
            end
          end

          warn("[OntoLex] Indexed #{activities.size} activities")
          activities
        end

        def index_agents(graph, submission)
          agents = []
          warn('[OntoLex] Indexing Agent (prov:Agent) objects...')

          agent_ids = subjects_of_type(graph, PROV.Agent)
          warn("[OntoLex] Found #{agent_ids.size} prov:Agent subjects")

          agent_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'agent')

            agent = LinkedData::Models::OntoLex::Agent.new(id: id)
            agent.submission = submission

            name = values_for(graph, orig_id, FOAF.name)
            agent.name = name if name

            mbox = values_for(graph, orig_id, FOAF.mbox)
            agent.mbox = mbox if mbox

            assoc_for = ref_values_for(graph, orig_id, PROV.wasAssociatedFor)
            agent.wasAssociatedFor = assoc_for if assoc_for && !assoc_for.empty?

            if agent.valid?
              agent.save(override_security: true)
              agents << agent
            else
              warn("[OntoLex] Agent INVALID: #{id}, errors: #{agent.errors}")
            end
          end

          warn("[OntoLex] Indexed #{agents.size} agents")
          agents
        end

        def index_skos_concepts(graph, submission)
          skos_concepts = []
          skos_concepts_by_id = {}

          warn('[OntoLex] Indexing SKOS Concept objects...')

          skos_ids = subjects_of_type(graph, SKOS.Concept)
          lexical_ids = subjects_of_type(graph, ONTOLEX.LexicalConcept)
          pure_skos_ids = skos_ids - lexical_ids

          warn("[OntoLex] Found #{pure_skos_ids.size} pure SKOS Concept subjects (#{skos_ids.size} total - #{lexical_ids.size} lexical)")

          pure_skos_ids.each do |orig_id|
            id = orig_id

            skos_concept = LinkedData::Models::Class.new(id: id)
            skos_concept.submission = submission

            pref_label = values_for(graph, orig_id, SKOS.prefLabel)
            skos_concept.prefLabel = pref_label if pref_label

            broader = values_for(graph, orig_id, SKOS.broader)
            if broader
              broader_array = broader.is_a?(Array) ? broader : [broader]
              broader_objs = broader_array.map { |uri| LinkedData::Models::Class.new(id: uri) }
              skos_concept.parents = broader_objs unless broader_objs.empty?
            end

            narrower = values_for(graph, orig_id, SKOS.narrower)
            if narrower
              narrower_array = narrower.is_a?(Array) ? narrower : [narrower]
            end

            in_scheme = values_for(graph, orig_id, SKOS.inScheme)
            if in_scheme
              in_scheme_array = in_scheme.is_a?(Array) ? in_scheme : [in_scheme]
              skos_concept.inScheme = in_scheme_array
            end

            if skos_concept.valid?
              warn("[OntoLex] Saving SKOS Concept #{id}")
              skos_concept.save(override_security: true)

              top_concept_of = values_for(graph, orig_id, SKOS.isTopConceptOf)
              if top_concept_of
                graph_uri = submission.id
                concept_uri = id
                top_concept_predicate = RDF::URI('http://www.w3.org/2004/02/skos/core#isTopConceptOf')

                client = Goo.sparql_query_client(:main)
                top_concept_array = top_concept_of.is_a?(Array) ? top_concept_of : [top_concept_of]
                top_concept_array.each do |tc|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{top_concept_predicate}> <#{tc}> } }"
                  begin
                    client.update(insert_query)
                    warn("[OntoLex] Manually inserted isTopConceptOf triple: #{concept_uri} -> #{tc}")
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert isTopConceptOf triple: #{e.message}")
                  end
                end
              end

              skos_concepts << skos_concept
              skos_concepts_by_id[orig_id] = skos_concept
              warn("[OntoLex] SKOS Concept saved successfully: prefLabel=#{skos_concept.prefLabel}")
            else
              warn("[OntoLex] SKOS Concept INVALID: #{id}, errors: #{skos_concept.errors}")
            end
          end

          warn("[OntoLex] Indexed #{skos_concepts.size} SKOS concepts")
          [skos_concepts_by_id, skos_concepts]
        end

        def index_concepts(graph, submission, skos_concepts_by_id = {})
          concepts = []
          concepts_by_id = {}
          ids = subjects_of_type(graph, ONTOLEX.LexicalConcept)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'concept')
            lc = LinkedData::Models::OntoLex::LexicalConcept.new(id: id)
            lc.submission = submission

            # Basic properties
            defs = values_for(graph, orig_id, SKOS.definition)
            lc.definition = Array(defs) if defs

            notes = values_for(graph, orig_id, SKOS.note)
            lc.note = Array(notes) if notes

            schemes = values_for(graph, orig_id, SKOS.inScheme)
            lc.inScheme = schemes.is_a?(Array) ? schemes.first : schemes if schemes

            pref_label = values_for(graph, orig_id, SKOS.prefLabel)
            lc.prefLabel = pref_label.is_a?(Array) ? pref_label.first : pref_label if pref_label

            source = values_for(graph, orig_id, DCTERMS.source)
            lc.source = source if source

            # Subject (link to SKOS Concept)
            subj_uri = values_for(graph, orig_id, DCTERMS.subject)
            if subj_uri
              subj_uri = subj_uri.is_a?(Array) ? subj_uri.first : subj_uri
              skos_concept = skos_concepts_by_id[subj_uri]
              lc.subject = skos_concept if skos_concept
              warn("[OntoLex] Linked LexicalConcept #{id} to SKOS Concept #{subj_uri}")
            end

            # Semantic relations within the same resource
            broader = ref_values_for(graph, orig_id, SKOS.broader)
            lc.broader = broader if broader && !broader.empty?

            narrower = ref_values_for(graph, orig_id, SKOS.narrower)
            lc.narrower = narrower if narrower && !narrower.empty?

            related = ref_values_for(graph, orig_id, SKOS.related)
            lc.related = related if related && !related.empty?

            # Mapping relations to other resources
            mapping_rel = ref_values_for(graph, orig_id, SKOS.mappingRelation)
            lc.mappingRelation = mapping_rel if mapping_rel && !mapping_rel.empty?

            broad_match = ref_values_for(graph, orig_id, SKOS.broadMatch)
            lc.broadMatch = broad_match if broad_match && !broad_match.empty?

            close_match = ref_values_for(graph, orig_id, SKOS.closeMatch)
            lc.closeMatch = close_match if close_match && !close_match.empty?

            exact_match = ref_values_for(graph, orig_id, SKOS.exactMatch)
            lc.exactMatch = exact_match if exact_match && !exact_match.empty?

            narrow_match = ref_values_for(graph, orig_id, SKOS.narrowMatch)
            lc.narrowMatch = narrow_match if narrow_match && !narrow_match.empty?

            related_match = ref_values_for(graph, orig_id, SKOS.relatedMatch)
            lc.relatedMatch = related_match if related_match && !related_match.empty?

            # Other semantic relations
            diff_from = ref_values_for(graph, orig_id, OWL.differentFrom)
            lc.differentFrom = diff_from if diff_from && !diff_from.empty?

            antonym = ref_values_for(graph, orig_id, LEXINFO.antonym)
            lc.antonym = antonym if antonym && !antonym.empty?

            is_part_of = ref_values_for(graph, orig_id, DCTERMS.isPartOf)
            lc.isPartOf = is_part_of if is_part_of && !is_part_of.empty?

            has_part = ref_values_for(graph, orig_id, DCTERMS.hasPart)
            lc.hasPart = has_part if has_part && !has_part.empty?

            # Domain-specific relations
            capital = ref_values_for(graph, orig_id, DBO.capital)
            lc.capital = capital if capital && !capital.empty?

            currency = ref_values_for(graph, orig_id, DBO.currency)
            lc.currency = currency if currency && !currency.empty?

            caused_by = ref_values_for(graph, orig_id, DBO.causedBy)
            lc.causedBy = caused_by if caused_by && !caused_by.empty?

            precedes = ref_values_for(graph, orig_id, RICO.precedesInTime)
            lc.precedesInTime = precedes if precedes && !precedes.empty?

            follows = ref_values_for(graph, orig_id, RICO.followsInTime)
            lc.followsInTime = follows if follows && !follows.empty?

            has_location = ref_values_for(graph, orig_id, DUL.hasLocation)
            lc.hasLocation = has_location if has_location && !has_location.empty?

            if lc.valid?
              warn('[OntoLex] Concept VALID, saving...')
              lc.save(override_security: true)
              warn('[OntoLex] Concept saved successfully')
            else
              warn("[OntoLex] Concept validation errors: #{lc.errors.inspect}")
            end
            concepts << lc
            concepts_by_id[orig_id] = lc
          end
          [concepts_by_id, concepts]
        end

        def index_forms(graph, submission)
          forms = {}
          ids = subjects_of_type(graph, ONTOLEX.Form)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'form')
            f = LinkedData::Models::OntoLex::Form.new(id: id)
            f.submission = submission

            wrep = values_for(graph, orig_id, ONTOLEX.writtenRep)
            if wrep && !wrep.is_a?(Array)
              f.writtenRep = wrep.respond_to?(:value) ? wrep.value : wrep.to_s
            elsif wrep.is_a?(Array)
              f.writtenRep = wrep.first.respond_to?(:value) ? wrep.first.value : wrep.first.to_s
            end

            langs = []
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.writtenRep)).each do |vs|
              langs << vs.object.language.to_s if vs.object.respond_to?(:language) && vs.object.language
            end
            f.language = langs.first unless langs.empty?

            gend = values_for(graph, orig_id, LEXINFO.gender)
            f.gender = gend if gend

            numb = values_for(graph, orig_id, LEXINFO.number)
            f.number = numb if numb

            # New: signedForm support
            signed_form = values_for(graph, orig_id, ETV.signedForm)
            f.signedForm = signed_form if signed_form

            if f.valid?
              warn('[OntoLex] Form VALID, saving...')
              f.save(override_security: true)
              warn('[OntoLex] Form saved successfully')
            else
              warn("[OntoLex] Form validation errors: #{f.errors.inspect}")
            end
            forms[orig_id] = f
          end
          forms
        end

        def index_senses(graph, submission, concepts_by_id)
          senses = {}
          ids = subjects_of_type(graph, ONTOLEX.LexicalSense)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'sense')
            s = LinkedData::Models::OntoLex::LexicalSense.new(id: id)
            s.submission  = submission
            s.definition  = values_for(graph, orig_id, DCTERMS.definition)
            s.example     = values_for(graph, orig_id, DCTERMS.example)
            s.reference   = values_for(graph, orig_id, ONTOLEX.reference)
            s.synonym     = ref_values_for(graph, orig_id, LEXINFO.synonym)
            s.translation = ref_values_for(graph, orig_id, VARTRANS.translation)

            # New properties
            norm_auth = values_for(graph, orig_id, LEXINFO.normativeAuthorization)
            s.normativeAuthorization = norm_auth if norm_auth

            term_type = values_for(graph, orig_id, LEXINFO.termType)
            s.termType = term_type if term_type

            usage_ex = ref_values_for(graph, orig_id, LEXICOG.usageExample)
            s.usageExample = usage_ex if usage_ex && !usage_ex.empty?

            rel_code = values_for(graph, orig_id, TERMLEX.reliabilityCode)
            s.reliabilityCode = rel_code if rel_code

            usage = ref_values_for(graph, orig_id, TERMLEX.usage)
            s.usage = usage if usage && !usage.empty?

            is_sense_of_uri = graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.isSenseOf)).map(&:object).first
            s.isSenseOf = is_sense_of_uri if is_sense_of_uri
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.isLexicalizedSenseOf)).each do |vs|
              concept = concepts_by_id[vs.object]
              s.lexicalConcept = concept if concept
            end
            if s.valid?
              warn('[OntoLex] Sense VALID, saving...')
              s.save(override_security: true)
              warn('[OntoLex] Sense saved successfully')
            else
              warn("[OntoLex] Sense validation errors: #{s.errors.inspect}")
            end
            senses[orig_id] = s
          end
          [senses, senses.values]
        end

        def index_entries(graph, submission, forms_by_id, senses_by_id, concepts_by_id, signed_forms_by_id = {})
          entries = []
          entries_by_id = {}
          ids = subjects_of_type(graph, ONTOLEX.LexicalEntry)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'entry')
            e = LinkedData::Models::OntoLex::LexicalEntry.new(id: id)
            e.submission = submission

            canon_form = values_for(graph, orig_id, ONTOLEX.canonicalForm)
            e.lemma = canon_form if canon_form

            lang = values_for(graph, orig_id, DCTERMS.language)
            e.language = lang if lang

            pos = values_for(graph, orig_id, LEXINFO.partOfSpeech)
            e.partOfSpeech = pos if pos

            tt = values_for(graph, orig_id, LEXINFO.termType)
            e.termType = tt if tt

            # New properties
            cas_num = values_for(graph, orig_id, DBO.casNumber)
            e.casNumber = cas_num if cas_num

            code = values_for(graph, orig_id, DBO.code)
            e.code = code if code

            valency = ref_values_for(graph, orig_id, OLIA.hasValency)
            e.hasValency = valency if valency && !valency.empty?

            # signedForm for entries - link to SignedForm objects
            signed_forms_list = []
            graph.query(subject: orig_id, predicate: conv_uri(ETV.signedForm)).each do |vs|
              sf = signed_forms_by_id[vs.object]
              signed_forms_list << sf if sf
            end
            e.signedForm = signed_forms_list unless signed_forms_list.empty?

            derived_from = ref_values_for(graph, orig_id, PROV.wasDerivedFrom)
            e.wasDerivedFrom = derived_from if derived_from && !derived_from.empty?

            influenced_by = ref_values_for(graph, orig_id, PROV.wasInfluencedBy)
            e.wasInfluencedBy = influenced_by if influenced_by && !influenced_by.empty?

            forms = []
            [ONTOLEX.canonicalForm, ONTOLEX.otherForm, ONTOLEX.lexicalForm].each do |pf|
              graph.query(subject: orig_id, predicate: conv_uri(pf)).each do |vs|
                forms << forms_by_id[vs.object] if forms_by_id[vs.object]
              end
            end
            e.form = forms unless forms.empty?

            linked_senses = []
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.sense)).each do |vs|
              s = senses_by_id[vs.object]
              linked_senses << s if s
            end
            e.sense = linked_senses unless linked_senses.empty?

            evoked_concept = nil
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.evokes)).each do |vs|
              c = concepts_by_id[vs.object]
              evoked_concept = c if c
              break # Only take the first one since it's a single-value attribute TODO: maybe handle multiple?
            end
            e.evokes = evoked_concept if evoked_concept

            if e.valid?
              e.save(override_security: true)
              if !forms.empty? || !linked_senses.empty? || !signed_forms_list.empty?
                graph_uri = submission.id
                entry_uri = e.id
                form_predicate = RDF::URI('http://www.w3.org/ns/lemon/ontolex#form')
                sense_predicate = RDF::URI('http://www.w3.org/ns/lemon/ontolex#sense')
                signed_form_predicate = RDF::URI('https://w3id.org/def/easytv#signedForm')

                client = Goo.sparql_query_client(:main)

                forms.each do |form|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{entry_uri}> <#{form_predicate}> <#{form.id}> } }"
                  begin
                    client.update(insert_query)
                    warn("[OntoLex] Manually inserted form triple: #{entry_uri} -> #{form.id}")
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert form triple: #{e.message}")
                  end
                end

                linked_senses.each do |sense|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{entry_uri}> <#{sense_predicate}> <#{sense.id}> } }"
                  begin
                    client.update(insert_query)
                    warn("[OntoLex] Manually inserted sense triple: #{entry_uri} -> #{sense.id}")
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert sense triple: #{e.message}")
                  end
                end

                signed_forms_list.each do |sf|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{entry_uri}> <#{signed_form_predicate}> <#{sf.id}> } }"
                  begin
                    client.update(insert_query)
                    warn("[OntoLex] Manually inserted signedForm triple: #{entry_uri} -> #{sf.id}")
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert signedForm triple: #{e.message}")
                  end
                end

                e.instance_variable_set(:@computed_forms, nil) if e.instance_variable_defined?(:@computed_forms)
                e.instance_variable_set(:@computed_senses, nil) if e.instance_variable_defined?(:@computed_senses)
                e.remove_instance_variable(:@computed_forms) if e.instance_variable_defined?(:@computed_forms)
                e.remove_instance_variable(:@computed_senses) if e.instance_variable_defined?(:@computed_senses)
              end
            else
              warn("[OntoLex] Entry validation errors: #{e.errors.inspect}")
            end
            entries << e
            entries_by_id[orig_id] = e
          end
          [entries_by_id, entries]
        end

        def link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)
          warn('[OntoLex] Starting second pass to link cross-references...')

          concepts_by_id.each do |orig_id, concept|
            evoked_by = ref_values_for(graph, orig_id, ONTOLEX.isEvokedBy)
            if evoked_by && !evoked_by.empty?
              evoked_entries = evoked_by.map { |uri| entries_by_id[uri] }.compact
              unless evoked_entries.empty?
                concept.isEvokedBy = evoked_entries
                warn("[OntoLex] Setting isEvokedBy for concept #{concept.id}: #{evoked_entries.size} entries")
              end
            end

            lex_senses = ref_values_for(graph, orig_id, ONTOLEX.lexicalizedSense)
            if lex_senses && !lex_senses.empty?
              sense_objs = lex_senses.map { |uri| senses_by_id[uri] }.compact
              unless sense_objs.empty?
                concept.lexicalizedSense = sense_objs
                warn("[OntoLex] Setting lexicalizedSense for concept #{concept.id}: #{sense_objs.size} senses")
              end
            end

            if concept.valid?
              graph_uri = submission.id
              concept_uri = concept.id
              isEvokedBy_predicate = RDF::URI('http://www.w3.org/ns/lemon/ontolex#isEvokedBy')
              lexicalizedSense_predicate = RDF::URI('http://www.w3.org/ns/lemon/ontolex#lexicalizedSense')

              client = Goo.sparql_query_client(:main)

              if concept.isEvokedBy && !concept.isEvokedBy.empty?
                concept.isEvokedBy.each do |entry|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{isEvokedBy_predicate}> <#{entry.id}> } }"
                  begin
                    client.update(insert_query)
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert isEvokedBy triple: #{e.message}")
                  end
                end
              end

              if concept.lexicalizedSense && !concept.lexicalizedSense.empty?
                concept.lexicalizedSense.each do |sense|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{lexicalizedSense_predicate}> <#{sense.id}> } }"
                  begin
                    client.update(insert_query)
                  rescue StandardError => e
                    warn("[OntoLex] Failed to insert lexicalizedSense triple: #{e.message}")
                  end
                end
              end

              warn("[OntoLex] Cross-references linked for concept #{concept.id}")
            else
              warn("[OntoLex] Concept validation errors during cross-reference linking: #{concept.errors.inspect}")
            end
          end

          warn('[OntoLex] Second pass completed')
        end

        def subjects_of_type(graph, type_uri)
          target = conv_uri(type_uri).to_s
          ids = Set.new
          graph.query(predicate: RDF.type).each do |st|
            ids << st.subject if st.object.to_s == target
          end
          ids
        end

        def values_for(graph, subject, predicate)
          pred = conv_uri(predicate)
          vals = []
          graph.query(subject: subject, predicate: pred).each do |st|
            vals << st.object
          end
          return nil if vals.empty?

          vals.length == 1 ? vals.first : vals
        end

        def ref_values_for(graph, subject, predicate)
          pred = conv_uri(predicate)
          vals = []
          graph.query(subject: subject, predicate: pred).each do |st|
            vals << st.object if st.object.is_a?(RDF::URI)
          end
          vals.empty? ? nil : vals
        end

        def conv_uri(term)
          term.respond_to?(:to_uri) ? term.to_uri : term
        end

        def skolemize_id(term, submission, kind)
          return term if term.is_a?(RDF::URI)

          node_id = term.to_s.gsub(/^_:/, '')
          prefix = LinkedData.settings.id_url_prefix || 'http://example.org'
          RDF::URI.new("#{prefix}/.well-known/genid/ontolex/#{submission&.submissionId}/#{kind}/#{CGI.escape(node_id)}")
        end
      end
    end
  end
end
