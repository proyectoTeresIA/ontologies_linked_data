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
        output_path = File.join(File.dirname(@file_path), "ontolex_triples.ttl")
        
        # Parse the OntoLex file and save to triple store
        OntoLex.parse(@file_path, @submission)
        
        @logger&.info("OntoLex parsing completed")
        
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
          STDERR.puts("[OntoLex] Graph statements: #{graph.count}")
          begin
            types = graph.query(predicate: RDF.type).objects.uniq.map(&:to_s)
            STDERR.puts("[OntoLex] RDF.type objects: #{types.join(', ')}")
          rescue StandardError
          end
          STDERR.puts("[OntoLex] SKOS Concept subjects: #{subjects_of_type(graph, SKOS.Concept).size}")
          STDERR.puts("[OntoLex] LexicalConcept subjects: #{subjects_of_type(graph, ONTOLEX.LexicalConcept).size}")
          STDERR.puts("[OntoLex] LexicalEntry subjects: #{subjects_of_type(graph, ONTOLEX.LexicalEntry).size}")
          STDERR.puts("[OntoLex] LexicalSense subjects: #{subjects_of_type(graph, ONTOLEX.LexicalSense).size}")
          STDERR.puts("[OntoLex] Form subjects: #{subjects_of_type(graph, ONTOLEX.Form).size}")
          
          # Parse definitions first so they exist when concepts reference them
          definitions = index_definitions(graph, submission)
          
          # Parse SKOS Concepts as Class objects (these are subjects for LexicalConcepts)
          skos_concepts_by_id, skos_concepts = index_skos_concepts(graph, submission)
          
          # Parse OntoLex LexicalConcepts
          concepts_by_id, concepts = index_concepts(graph, submission, skos_concepts_by_id)
          forms    = index_forms(graph, submission)
          senses_by_id, senses = index_senses(graph, submission, concepts_by_id)
          entries_by_id, entries = index_entries(graph, submission, forms, senses_by_id, concepts_by_id)
          
          # Second pass: link cross-references now that all objects exist
          link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)
          
          { entries: entries, senses: senses, concepts: concepts, forms: forms, definitions: definitions, skos_concepts: skos_concepts }
        end

        def load_graph(rdf_source)
          STDERR.puts("[OntoLex] Loading RDF from source: #{rdf_source}")
          ext = rdf_source.is_a?(String) ? File.extname(rdf_source).downcase : nil
          
          # Use the lower-level approach that works - similar to the original load_graph method
          graph = RDF::Graph.new
          
          if File.file?(rdf_source)
            content = File.read(rdf_source)
            STDERR.puts("[OntoLex] Read #{content.bytesize} bytes from file")
            
            case ext
            when '.nt', '.ntriples'
              STDERR.puts("[OntoLex] Parsing as N-Triples")
              reader = RDF::NTriples::Reader.new(content)
              reader.each_statement { |st| graph << st }
            when '.ttl', '.turtle'
              STDERR.puts("[OntoLex] Parsing as Turtle")
              # RDF 1.0.x has a bug with TTL base_uri handling that causes join errors
              # Workaround: Convert TTL to N-Triples using external parser then parse
              # TODO: Update GOO gem to use RDF 3.x which fixes this issue
              success = false

              unless success
                begin
                  nt_content = `rapper -i turtle -o ntriples "#{rdf_source}" 2>/dev/null`
                  if $?.success? && !nt_content.empty?
                    STDERR.puts("[OntoLex] Converted TTL to N-Triples using rapper: #{nt_content.lines.count} lines")
                    reader = RDF::NTriples::Reader.new(nt_content)
                    reader.each_statement { |st| graph << st }
                    STDERR.puts("[OntoLex] TTL converted and parsed successfully")
                    success = true
                  end
                rescue StandardError => e
                  STDERR.puts("[OntoLex] rapper failed: #{e.message}")
                end
              end
              
              unless success
                STDERR.puts("[OntoLex] All TTL conversion tools failed")
                raise StandardError.new("Unable to parse TTL file: #{rdf_source}. RDF 1.0.x has TTL parsing issues.")
              end
            else
              STDERR.puts("[OntoLex] Unknown format: #{ext}")
              raise StandardError.new("Unsupported file format: #{ext}. Only .nt, .ntriples, .ttl, .turtle are supported.")
            end
          else
            STDERR.puts("[OntoLex] Source is not a file: #{rdf_source}")
            raise ArgumentError.new("Source must be a file path: #{rdf_source}")
          end
          
          STDERR.puts("[OntoLex] Loaded #{graph.count} statements")
          graph
        end

        def index_definitions(graph, submission)
          definitions = []
          STDERR.puts("[OntoLex] Indexing Definition objects...")
          
          def_ids = subjects_of_type(graph, TERMLEX.Definition)
          STDERR.puts("[OntoLex] Found #{def_ids.size} Definition subjects")
          
          def_ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'definition')
            
            defn = LinkedData::Models::OntoLex::Definition.new(id: id)
            defn.submission = submission
            
            lang = values_for(graph, orig_id, DCTERMS.language)
            defn.language = lang if lang
            
            label = values_for(graph, orig_id, RDF::RDFS.label)
            defn.label = label if label
            
            if defn.valid?
              STDERR.puts("[OntoLex] Saving Definition #{id}")
              defn.save(override_security: true)
              definitions << defn
              STDERR.puts("[OntoLex] Definition saved successfully: language=#{defn.language}, label_length=#{defn.label&.to_s&.length || 0}")
            else
              STDERR.puts("[OntoLex] Definition INVALID: #{id}, errors: #{defn.errors}")
            end
          end
          
          STDERR.puts("[OntoLex] Indexed #{definitions.size} definitions")
          definitions
        end

        def index_skos_concepts(graph, submission)
          skos_concepts = []
          skos_concepts_by_id = {}
          
          STDERR.puts("[OntoLex] Indexing SKOS Concept objects...")
          
          skos_ids = subjects_of_type(graph, SKOS.Concept)
          lexical_ids = subjects_of_type(graph, ONTOLEX.LexicalConcept)
          pure_skos_ids = skos_ids - lexical_ids
          
          STDERR.puts("[OntoLex] Found #{pure_skos_ids.size} pure SKOS Concept subjects (#{skos_ids.size} total - #{lexical_ids.size} lexical)")
          
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
              STDERR.puts("[OntoLex] Saving SKOS Concept #{id}")
              skos_concept.save(override_security: true)
              
              top_concept_of = values_for(graph, orig_id, SKOS.isTopConceptOf)
              if top_concept_of
                graph_uri = submission.id
                concept_uri = id
                top_concept_predicate = RDF::URI("http://www.w3.org/2004/02/skos/core#isTopConceptOf")
                
                client = Goo.sparql_query_client(:main)
                top_concept_array = top_concept_of.is_a?(Array) ? top_concept_of : [top_concept_of]
                top_concept_array.each do |tc|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{top_concept_predicate}> <#{tc}> } }"
                  begin
                    client.update(insert_query)
                    STDERR.puts("[OntoLex] Manually inserted isTopConceptOf triple: #{concept_uri} -> #{tc}")
                  rescue => ex
                    STDERR.puts("[OntoLex] Failed to insert isTopConceptOf triple: #{ex.message}")
                  end
                end
              end
              
              skos_concepts << skos_concept
              skos_concepts_by_id[orig_id] = skos_concept
              STDERR.puts("[OntoLex] SKOS Concept saved successfully: prefLabel=#{skos_concept.prefLabel}")
            else
              STDERR.puts("[OntoLex] SKOS Concept INVALID: #{id}, errors: #{skos_concept.errors}")
            end
          end
          
          STDERR.puts("[OntoLex] Indexed #{skos_concepts.size} SKOS concepts")
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
            defs = values_for(graph, orig_id, SKOS.definition)
            lc.definition = Array(defs) if defs
            schemes = values_for(graph, orig_id, SKOS.inScheme)
            lc.inScheme = schemes.is_a?(Array) ? schemes.first : schemes if schemes
            pref_label = values_for(graph, orig_id, SKOS.prefLabel)
            lc.prefLabel = pref_label.is_a?(Array) ? pref_label.first : pref_label if pref_label
            subj_uri = values_for(graph, orig_id, DCTERMS.subject)
            if subj_uri
              subj_uri = subj_uri.is_a?(Array) ? subj_uri.first : subj_uri
              skos_concept = skos_concepts_by_id[subj_uri]
              lc.subject = skos_concept if skos_concept
              STDERR.puts("[OntoLex] Linked LexicalConcept #{id} to SKOS Concept #{subj_uri}")
            end
            if lc.valid?
              STDERR.puts("[OntoLex] Concept VALID, saving...")
              lc.save(override_security: true)
              STDERR.puts("[OntoLex] Concept saved successfully")
            else
              STDERR.puts("[OntoLex] Concept validation errors: #{lc.errors.inspect}")
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
            if f.valid?
              STDERR.puts("[OntoLex] Form VALID, saving...")
              f.save(override_security: true)
              STDERR.puts("[OntoLex] Form saved successfully")
            else
              STDERR.puts("[OntoLex] Form validation errors: #{f.errors.inspect}")
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
            is_sense_of_uri = graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.isSenseOf)).map(&:object).first
            s.isSenseOf = is_sense_of_uri if is_sense_of_uri
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.isLexicalizedSenseOf)).each do |vs|
              concept = concepts_by_id[vs.object]
              s.lexicalConcept = concept if concept
            end
            if s.valid?
              STDERR.puts("[OntoLex] Sense VALID, saving...")
              s.save(override_security: true)
              STDERR.puts("[OntoLex] Sense saved successfully")
            else
              STDERR.puts("[OntoLex] Sense validation errors: #{s.errors.inspect}")
            end
            senses[orig_id] = s
          end
          [senses, senses.values]
        end

        def index_entries(graph, submission, forms_by_id, senses_by_id, concepts_by_id)
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
            forms = []
            [ONTOLEX.canonicalForm, ONTOLEX.otherForm, ONTOLEX.lexicalForm].each do |pf|
              graph.query(subject: orig_id, predicate: conv_uri(pf)).each { |vs| forms << forms_by_id[vs.object] if forms_by_id[vs.object] }
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
              break  # Only take the first one since it's a single-value attribute TODO: maybe handle multiple?
            end
            e.evokes = evoked_concept if evoked_concept
            if e.valid?
              e.save(override_security: true)
              if !forms.empty? || !linked_senses.empty?
                graph_uri = submission.id
                entry_uri = e.id
                form_predicate = RDF::URI("http://www.w3.org/ns/lemon/ontolex#form")
                sense_predicate = RDF::URI("http://www.w3.org/ns/lemon/ontolex#sense")
                
                client = Goo.sparql_query_client(:main)
                
                forms.each do |form|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{entry_uri}> <#{form_predicate}> <#{form.id}> } }"
                  begin
                    client.update(insert_query)
                    STDERR.puts("[OntoLex] Manually inserted form triple: #{entry_uri} -> #{form.id}")
                  rescue => ex
                    STDERR.puts("[OntoLex] Failed to insert form triple: #{ex.message}")
                  end
                end
                
                linked_senses.each do |sense|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{entry_uri}> <#{sense_predicate}> <#{sense.id}> } }"
                  begin
                    client.update(insert_query)
                    STDERR.puts("[OntoLex] Manually inserted sense triple: #{entry_uri} -> #{sense.id}")
                  rescue => ex
                    STDERR.puts("[OntoLex] Failed to insert sense triple: #{ex.message}")
                  end
                end
                
                e.instance_variable_set(:@computed_forms, nil) if e.instance_variable_defined?(:@computed_forms)
                e.instance_variable_set(:@computed_senses, nil) if e.instance_variable_defined?(:@computed_senses)
                e.remove_instance_variable(:@computed_forms) if e.instance_variable_defined?(:@computed_forms)
                e.remove_instance_variable(:@computed_senses) if e.instance_variable_defined?(:@computed_senses)
              end
            else
              STDERR.puts("[OntoLex] Entry validation errors: #{e.errors.inspect}")
            end
            entries << e
            entries_by_id[orig_id] = e
          end
          [entries_by_id, entries]
        end

        def link_cross_references(graph, concepts_by_id, entries_by_id, senses_by_id, submission)
          STDERR.puts("[OntoLex] Starting second pass to link cross-references...")
          
          concepts_by_id.each do |orig_id, concept|
            evoked_by = ref_values_for(graph, orig_id, ONTOLEX.isEvokedBy)
            if evoked_by && !evoked_by.empty?
              evoked_entries = evoked_by.map { |uri| entries_by_id[uri] }.compact
              unless evoked_entries.empty?
                concept.isEvokedBy = evoked_entries
                STDERR.puts("[OntoLex] Setting isEvokedBy for concept #{concept.id}: #{evoked_entries.size} entries")
              end
            end
            
            lex_senses = ref_values_for(graph, orig_id, ONTOLEX.lexicalizedSense)
            if lex_senses && !lex_senses.empty?
              sense_objs = lex_senses.map { |uri| senses_by_id[uri] }.compact
              unless sense_objs.empty?
                concept.lexicalizedSense = sense_objs
                STDERR.puts("[OntoLex] Setting lexicalizedSense for concept #{concept.id}: #{sense_objs.size} senses")
              end
            end
            
            if concept.valid?
              graph_uri = submission.id
              concept_uri = concept.id
              isEvokedBy_predicate = RDF::URI("http://www.w3.org/ns/lemon/ontolex#isEvokedBy")
              lexicalizedSense_predicate = RDF::URI("http://www.w3.org/ns/lemon/ontolex#lexicalizedSense")
              
              client = Goo.sparql_query_client(:main)
              
              if concept.isEvokedBy && !concept.isEvokedBy.empty?
                concept.isEvokedBy.each do |entry|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{isEvokedBy_predicate}> <#{entry.id}> } }"
                  begin
                    client.update(insert_query)
                  rescue => ex
                    STDERR.puts("[OntoLex] Failed to insert isEvokedBy triple: #{ex.message}")
                  end
                end
              end
              
              if concept.lexicalizedSense && !concept.lexicalizedSense.empty?
                concept.lexicalizedSense.each do |sense|
                  insert_query = "INSERT DATA { GRAPH <#{graph_uri}> { <#{concept_uri}> <#{lexicalizedSense_predicate}> <#{sense.id}> } }"
                  begin
                    client.update(insert_query)
                  rescue => ex
                    STDERR.puts("[OntoLex] Failed to insert lexicalizedSense triple: #{ex.message}")
                  end
                end
              end
              
              STDERR.puts("[OntoLex] Cross-references linked for concept #{concept.id}")
            else
              STDERR.puts("[OntoLex] Concept validation errors during cross-reference linking: #{concept.errors.inspect}")
            end
          end
          
          STDERR.puts("[OntoLex] Second pass completed")
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
