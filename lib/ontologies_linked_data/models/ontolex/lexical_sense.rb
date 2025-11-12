module LinkedData
  module Models
    module OntoLex
      class LexicalSense < LinkedData::Models::Base
        model :lexical_sense, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#LexicalSense") }

        attribute :definition, namespace: :dcterms
        attribute :example, namespace: :dcterms, property: :example
        attribute :reference, namespace: :ontolex
        attribute :synonym, namespace: :lexinfo, property: :synonym, enforce: [:list]
        attribute :translation, namespace: :vartrans, property: :translation, enforce: [:list]
        attribute :normativeAuthorization, namespace: :lexinfo, property: :normativeAuthorization
        attribute :usageExample, namespace: :lexicog, property: :usageExample
        attribute :reliabilityCode, namespace: :termlex, property: :reliabilityCode
        attribute :usage, namespace: :termlex, property: :usage
        attribute :isSenseOf, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::LexicalEntry }
        attribute :lexicalConcept, namespace: :ontolex, property: :isLexicalizedSenseOf, range: -> { LinkedData::Models::OntoLex::LexicalConcept }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :definition, :example, :reference, :lexicalConcept, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage, :isSenseOf
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_senses/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          self.unmapped
        end

        def to_hash(options = {})
          super(options)
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission
          
          # Now using standard Goo patterns with properly persisted data
          include_attrs = [:definition, :example, :reference, :lexicalConcept, :synonym, :translation, :isSenseOf] if include_attrs.empty?
          
          LexicalSense.in(submission).include(*include_attrs).page(page, size).all
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          
          include_attrs = [:definition, :example, :reference, :lexicalConcept, :synonym, :translation, :isSenseOf] if include_attrs.empty?
          
          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          sense_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)
            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?
              RDF::URI.new(uri_str)  # Use .new() instead of call syntax
            rescue => e
              puts "[LexicalSense] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          return [] if sense_ids.empty?
          
          # Query each ID individually and collect results
          sense_ids.map do |uri|
            LexicalSense.find(uri).in(submission).include(*include_attrs).first
          end.compact
        end

        def self.count_in_submission(submission)
          return 0 unless submission
          begin
            LexicalSense.in(submission).count
          rescue StandardError => e
            puts "[LexicalSense] Error counting: #{e.message}"
            0
          end
        end
      end
    end
  end
end
