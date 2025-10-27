require 'rdf'
require 'rdf/turtle'
require 'rdf/ntriples'
require 'addressable/uri'
require 'cgi'
require 'set'

module LinkedData
  module Parser
    class OntoLex
      ONTOLEX   = RDF::Vocabulary.new('http://www.w3.org/ns/lemon/ontolex#')
      LEXINFO   = RDF::Vocabulary.new('http://www.lexinfo.net/ontology/3.0/lexinfo#')
      SKOS      = RDF::Vocabulary.new('http://www.w3.org/2004/02/skos/core#')
      DCTERMS   = RDF::Vocabulary.new('http://purl.org/dc/terms/')
      RDF_TYPE  = [
        RDF::URI('http://www.w3.org/1999/02/22-rdf-syntax-ns#type'),
        RDF::URI('https://www.w3.org/1999/02/22-rdf-syntax-ns#type')
      ]

      class << self
        def parse(rdf_source, submission, options = {})
          raise ArgumentError, 'submission is required' unless submission
          graph = load_graph(rdf_source)
          STDERR.puts("[OntoLex] Graph statements: #{graph.count}")
          begin
            types = graph.query(predicate: RDF.type).objects.uniq.map(&:to_s)
            STDERR.puts("[OntoLex] RDF.type objects: #{types.join(', ')}")
          rescue StandardError
          end
          STDERR.puts("[OntoLex] SKOSConcept subjects: #{subjects_of_type(graph, SKOS.Concept).size}")
          STDERR.puts("[OntoLex] LexicalConcept subjects: #{subjects_of_type(graph, ONTOLEX.LexicalConcept).size}")
          STDERR.puts("[OntoLex] LexicalEntry subjects: #{subjects_of_type(graph, ONTOLEX.LexicalEntry).size}")
          STDERR.puts("[OntoLex] LexicalSense subjects: #{subjects_of_type(graph, ONTOLEX.LexicalSense).size}")
          STDERR.puts("[OntoLex] Form subjects: #{subjects_of_type(graph, ONTOLEX.Form).size}")
          concepts_by_id, concepts = index_concepts(graph, submission)
          forms    = index_forms(graph, submission)
          senses   = index_senses(graph, submission, concepts_by_id)
          entries  = index_entries(graph, submission, forms, senses)
          { entries: entries, senses: senses, concepts: concepts, forms: forms }
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


        def index_concepts(graph, submission)
          concepts = []
          concepts_by_id = {}
          ids = subjects_of_type(graph, ONTOLEX.LexicalConcept) | subjects_of_type(graph, SKOS.Concept)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'concept')
            lc = LinkedData::Models::OntoLex::LexicalConcept.new(id: id)
            lc.submission = submission
            lc.prefLabel = values_for(graph, orig_id, SKOS.prefLabel)
            lc.definition = values_for(graph, orig_id, SKOS.definition)
            lc.broader = values_for(graph, orig_id, SKOS.broader)
            lc.narrower = values_for(graph, orig_id, SKOS.narrower)
            lc.save if lc.valid?
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
            f.writtenRep = values_for(graph, orig_id, ONTOLEX.writtenRep)
            f.formType   = values_for(graph, orig_id, ONTOLEX.formType)
            langs = []
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.writtenRep)).each do |vs|
              langs << vs.object.language.to_s if vs.object.respond_to?(:language) && vs.object.language
            end
            f.language = langs.uniq unless langs.empty?
            f.save if f.valid?
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
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.isLexicalizedSenseOf)).each do |vs|
              concept = concepts_by_id[vs.object]
              s.lexicalConcept = [concept] if concept
            end
            s.save if s.valid?
            senses[orig_id] = s
          end
          senses
        end

        def index_entries(graph, submission, forms_by_id, senses_by_id)
          entries = []
          ids = subjects_of_type(graph, ONTOLEX.LexicalEntry)
          ids.each do |orig_id|
            id = skolemize_id(orig_id, submission, 'entry')
            e = LinkedData::Models::OntoLex::LexicalEntry.new(id: id)
            e.submission = submission
            e.lemma      = values_for(graph, orig_id, ONTOLEX.canonicalForm)
            e.language   = values_for(graph, orig_id, DCTERMS.language)
            e.partOfSpeech = values_for(graph, orig_id, LEXINFO.partOfSpeech)
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
            concepts = []
            graph.query(subject: orig_id, predicate: conv_uri(ONTOLEX.evokes)).each do |vs|
              concepts << vs.object
            end
            e.concept = concepts unless concepts.empty?
            e.save if e.valid?
            entries << e
          end
          entries
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

        def conv_uri(term)
          term.respond_to?(:to_uri) ? term.to_uri : term
        end

        # Mint a stable URI for blank node subjects on ingestion time to avoid RDF::Node IDs
        # The URI format uses the instance id_url_prefix and submission to remain stable per submission
        def skolemize_id(term, submission, kind)
          return term if term.is_a?(RDF::URI)
          # Build a deterministic token from the RDF::Node identifier
          node_id = term.to_s.gsub(/^_:/, '')
          prefix = LinkedData.settings.id_url_prefix || 'http://example.org'
          RDF::URI.new("#{prefix}/.well-known/genid/ontolex/#{submission&.submissionId}/#{kind}/#{CGI.escape(node_id)}")
        end
      end
    end
  end
end
