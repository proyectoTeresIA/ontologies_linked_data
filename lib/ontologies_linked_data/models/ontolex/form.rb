module LinkedData
  module Models
    module OntoLex
      class Form < LinkedData::Models::Base
        model :form, name_with: :id, collection: :submission,
                     namespace: :ontolex, schemaless: :true,
                     rdf_type: ->(*_x) { RDF::URI("http://www.w3.org/ns/lemon/ontolex#Form") }

        attribute :writtenRep, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :gender, namespace: :lexinfo, property: :gender
        attribute :number, namespace: :lexinfo, property: :number
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :writtenRep, :gender, :number
        serialize_never :submission
        serialize_methods :properties, :computed

        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/forms/#{CGI.escape(s.id.to_s)}" }, self.uri_type)

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          self.unmapped
        end

        def to_hash(options = {})
          super(options)
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          
          include_attrs = [:writtenRep, :language, :gender, :number] if include_attrs.empty?
          
          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          form_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)
            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?
              RDF::URI.new(uri_str)
            rescue => e
              puts "[Form] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          return [] if form_ids.empty?
          
          # Query each ID individually and collect results
          form_ids.map do |uri|
            Form.find(uri).in(submission).include(*include_attrs).first
          end.compact
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission
          
          # Now using standard Goo patterns with properly persisted data
          include_attrs = [:writtenRep, :language, :gender, :number] if include_attrs.empty?
          
          Form.in(submission).include(*include_attrs).page(page, size).all
        end

        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          entry_type = "http://www.w3.org/ns/lemon/ontolex#LexicalEntry"
          form_p = "http://www.w3.org/ns/lemon/ontolex#form"
          lex_form_p = "http://www.w3.org/ns/lemon/ontolex#lexicalForm"
          can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
          oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
          l_form_p = "http://lemon-model.net/lemon#form"
          l_can_p = "http://lemon-model.net/lemon#canonicalForm"
          l_oth_p = "http://lemon-model.net/lemon#otherForm"
          type_uri = "http://www.w3.org/ns/lemon/ontolex#Form"
          l_type_uri = "http://lemon-model.net/lemon#Form"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?f) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?e a <#{entry_type}> . ?e (<#{form_p}>|<#{lex_form_p}>|<#{can_p}>|<#{oth_p}>|<#{l_form_p}>|<#{l_can_p}>|<#{l_oth_p}>) ?f }",
              "    UNION { ?f a <#{type_uri}> }",
              "    UNION { ?f a <#{l_type_uri}> }",
              "    FILTER(isIRI(?f))",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q, graphs: [graph]).first
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end
      end
    end
  end
end
