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
          
          # Batch query for all sense properties
          def_p = "http://purl.org/dc/terms/definition"
          def_p2 = "http://purl.org/dc/terms/description"
          def_p3 = "http://www.w3.org/2004/02/skos/core#definition"
          def_p4 = "http://www.w3.org/2000/01/rdf-schema#comment"
          ex_p = "http://purl.org/dc/terms/example"
          ref_p = "http://www.w3.org/ns/lemon/ontolex#reference"
          syn_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#synonym"
          syn_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#synonym"
          tr_p = "http://www.w3.org/ns/lemon/vartrans#translation"
          na_p = "http://www.lexinfo.net/ontology/3.0/lexinfo#normativeAuthorization"
          na_p2 = "http://lexinfo.net/ontology/2.0/lexinfo#normativeAuthorization"
          ue_p = "http://www.w3.org/ns/lemon/lime#usageExample"
          ue_p2 = "https://www.w3.org/ns/lemon/lexicog#usageExample"
          ue_p3 = "http://www.w3.org/ns/lemon/lexicog#usageExample"
          rc_p = "https://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          rc_p2 = "http://termlex.oeg.fi.upm.es/termlex/reliabilityCode"
          usg_p = "https://termlex.oeg.fi.upm.es/termlex/usage"
          usg_p2 = "http://termlex.oeg.fi.upm.es/termlex/usage"
          lc_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          
          values = ids.map { |id| "<#{id}>" }.join(" ")
          batch_q = [
            "SELECT ?s ?p ?o WHERE {",
            "  GRAPH <#{graph}> {",
            "    VALUES ?s { #{values} }",
            "    {",
            "      ?s ?p ?o .",
            "      FILTER(?p IN (<#{def_p}>, <#{def_p2}>, <#{def_p3}>, <#{def_p4}>, <#{ex_p}>, <#{ref_p}>, <#{syn_p}>, <#{syn_p2}>, <#{tr_p}>, <#{na_p}>, <#{na_p2}>, <#{ue_p}>, <#{ue_p2}>, <#{ue_p3}>, <#{rc_p}>, <#{rc_p2}>, <#{usg_p}>, <#{usg_p2}>, <#{lc_p}>))",
            "    } UNION {",
            "      ?c <#{lc_inv_p}> ?s .",
            "      BIND(<#{lc_p}> AS ?p)",
            "      BIND(?c AS ?o)",
            "    }",
            "  }",
            "}",
          ].join("\n")
          
          # Collect results by sense ID
          sense_attrs = {}
          ids.each { |id| sense_attrs[id] = { id: RDF::URI(id), submission: submission } }
          
          begin
            epr.query(batch_q, graphs: [graph]).each do |row|
              sid = row[:s].to_s
              next unless sense_attrs[sid]
              
              case row[:p].to_s
              when def_p, def_p2, def_p3, def_p4
                (sense_attrs[sid][:definition] ||= []) << row[:o].to_s
              when ex_p
                (sense_attrs[sid][:example] ||= []) << row[:o].to_s
              when ref_p
                (sense_attrs[sid][:reference] ||= []) << row[:o].to_s
              when syn_p, syn_p2
                (sense_attrs[sid][:synonym] ||= []) << row[:o].to_s
              when tr_p
                (sense_attrs[sid][:translation] ||= []) << row[:o].to_s
              when na_p, na_p2
                (sense_attrs[sid][:normativeAuthorization] ||= []) << row[:o].to_s
              when ue_p, ue_p2, ue_p3
                (sense_attrs[sid][:usageExample] ||= []) << row[:o].to_s
              when rc_p, rc_p2
                (sense_attrs[sid][:reliabilityCode] ||= []) << row[:o].to_s
              when usg_p, usg_p2
                (sense_attrs[sid][:usage] ||= []) << row[:o].to_s
              when lc_p
                (sense_attrs[sid][:lexicalConcept] ||= []) << row[:o].to_s
              end
            end
          rescue StandardError
          end
          
          # Dedup and create read_only objects
          sense_attrs.values.map do |attrs|
            # Most attributes can have multiple values
            [:definition, :example, :reference, :synonym, :translation, :normativeAuthorization, :usageExample, :reliabilityCode, :usage].each do |k|
              arr = attrs[k]
              attrs[k] = arr.uniq if arr.respond_to?(:uniq)
            end
            # lexicalConcept is a single value - take first from array
            if attrs[:lexicalConcept].is_a?(Array)
              attrs[:lexicalConcept] = attrs[:lexicalConcept].first
            end
            LinkedData::Models::OntoLex::LexicalSense.read_only(attrs)
          end
        end
        def self.count_in_submission(submission)
          return 0 unless submission
          graph = submission.id
          entry_type = "http://www.w3.org/ns/lemon/ontolex#LexicalEntry"
          sense_type = "http://www.w3.org/ns/lemon/ontolex#LexicalSense"
          sense_p = "http://www.w3.org/ns/lemon/ontolex#sense"
          isSenseOf_p = "http://www.w3.org/ns/lemon/ontolex#isSenseOf"
          lex_sense_p = "http://www.w3.org/ns/lemon/ontolex#lexicalizedSense"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?s) AS ?count) WHERE {",
              "  GRAPH <#{graph}> {",
              "    { ?e a <#{entry_type}> . { ?e <#{sense_p}> ?s } UNION { ?s <#{isSenseOf_p}> ?e } }",
              "    UNION { ?s a <#{sense_type}> }",
              "    UNION { ?lc <#{lex_sense_p}> ?s }",
              "    FILTER(isIRI(?s))",
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
