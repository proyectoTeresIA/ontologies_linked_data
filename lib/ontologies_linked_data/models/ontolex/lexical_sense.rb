module LinkedData
  module Models
    module OntoLex
      class LexicalSense < LinkedData::Models::Base
        model :lexical_sense, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { Goo.vocabulary(:ontolex)['LexicalSense'] }

        attribute :definition, namespace: :dcterms
        attribute :example, namespace: :dcterms, property: :example
        attribute :reference, namespace: :ontolex
        attribute :synonym, namespace: :lexinfo, property: :synonym, enforce: [:list]
        attribute :translation, namespace: :vartrans, property: :translation, enforce: [:list]
        attribute :normativeAuthorization, namespace: :lexinfo, property: :normativeAuthorization
        attribute :termType, namespace: :lexinfo, property: :termType
        attribute :usageExample, namespace: :lexicog, property: :usageExample, enforce: [:list], range: -> { LinkedData::Models::OntoLex::UsageExample }
        attribute :reliabilityCode, namespace: :termlex, property: :reliabilityCode
        attribute :usage, namespace: :termlex, property: :usage, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Usage }
        attribute :isSenseOf, namespace: :ontolex, range: -> { LinkedData::Models::OntoLex::LexicalEntry }
        attribute :lexicalConcept, namespace: :ontolex, property: :isLexicalizedSenseOf, range: lambda {
          LinkedData::Models::OntoLex::LexicalConcept
        }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :definition, :example, :reference, :lexicalConcept, :synonym, :translation,
                          :normativeAuthorization, :termType, :usageExample, :reliabilityCode, :usage, :isSenseOf
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', lambda { |s|
          "ontologies/#{s.submission.ontology.acronym}/lexical_senses/#{CGI.escape(s.id.to_s)}"
        }, uri_type),
                LinkedData::Hypermedia::Link.new('ontology', lambda { |s|
                  "ontologies/#{s.submission.ontology.acronym}"
                }, Goo.vocabulary['Ontology'])

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          unmapped
        end

        def to_hash(options = {})
          super(options)
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission

          # Now using standard Goo patterns with properly persisted data
          if include_attrs.empty?
            include_attrs = %i[definition example reference lexicalConcept synonym translation
                               isSenseOf usageExample usage normativeAuthorization termType reliabilityCode]
          end

          senses = LexicalSense.in(submission).include(*include_attrs).page(page, size).all
          
          # Expand usage examples and usages
          senses.each { |s| expand_sense_attributes(s, submission) }
          senses
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?

          if include_attrs.empty?
            include_attrs = %i[definition example reference lexicalConcept synonym translation
                               isSenseOf usageExample usage normativeAuthorization termType reliabilityCode]
          end

          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          sense_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)

            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?

              RDF::URI.new(uri_str) # Use .new() instead of call syntax
            rescue StandardError => e
              puts "[LexicalSense] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          return [] if sense_ids.empty?

          # Query each ID individually and collect results
          senses = sense_ids.map do |uri|
            LexicalSense.find(uri).in(submission).include(*include_attrs).first
          end.compact
          
          # Expand usage examples and usages
          senses.each { |s| expand_sense_attributes(s, submission) }
          senses
        end

        # Expand usage-related attributes for a sense
        def self.expand_sense_attributes(sense, submission)
          return unless sense

          # Expand usageExample (UsageExample objects)
          if sense.usageExample
            sense.usageExample = Array(sense.usageExample).map do |ue|
              expand_usage_example(ue, submission)
            end.compact
          end

          # Expand usage (Usage objects)
          if sense.usage
            sense.usage = Array(sense.usage).map do |u|
              expand_usage(u, submission)
            end.compact
          end
        end

        # Helper to expand UsageExample
        def self.expand_usage_example(ue_obj, submission)
          LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(
            ue_obj, submission, 'UsageExample', %w[language value source]
          )
        end

        # Helper to expand Usage
        def self.expand_usage(usage_obj, submission)
          LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(
            usage_obj, submission, 'Usage', %w[language value source]
          )
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
