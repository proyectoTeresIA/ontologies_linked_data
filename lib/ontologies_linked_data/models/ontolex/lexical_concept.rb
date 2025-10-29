module LinkedData
  module Models
    module OntoLex
      class LexicalConcept < LinkedData::Models::Base
        model :lexical_concept, name_with: :id, collection: :submission,
                                namespace: :ontolex, schemaless: :true,
                                rdf_type: ->(*_x) { RDF::URI('http://www.w3.org/ns/lemon/ontolex#LexicalConcept') }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :definition, namespace: :skos, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Definition }
        attribute :prefLabel, namespace: :skos
        attribute :inScheme, namespace: :skos
        attribute :subject, namespace: :dcterms, range: -> { LinkedData::Models::Class }
        attribute :isEvokedBy, namespace: :ontolex, enforce: [:list]
        attribute :lexicalizedSense, namespace: :ontolex, property: :lexicalizedSense, enforce: [:list], range: -> { LinkedData::Models::OntoLex::LexicalSense }

        serialize_default :definition, :prefLabel, :inScheme, :subject, :isEvokedBy, :lexicalizedSense
        serialize_never :submission
        serialize_methods :properties

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        # IMPORTANT: Methods that depend on the existence of entities should return values only after all parsing is complete
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new("self", ->(s) { "ontologies/#{s.submission.ontology.acronym}/lexical_concepts/#{CGI.escape(s.id.to_s)}" }, self.uri_type),
                LinkedData::Hypermedia::Link.new("ontology", ->(s) { "ontologies/#{s.submission.ontology.acronym}" }, Goo.vocabulary["Ontology"])

        def properties
          self.unmapped
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission
          
          # Load basic attributes - will be expanded manually
          include_attrs = [:definition, :prefLabel, :inScheme, :subject, :isEvokedBy, :lexicalizedSense] if include_attrs.empty?
          
          # Use standard Goo query with .in(submission) to filter by graph
          concepts = LexicalConcept.in(submission).include(*include_attrs).page(page, size).all
          
          # Manually expand definition and subject for each concept
          concepts.each do |concept|
            expand_concept_attributes(concept, submission)
          end
          
          concepts
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?
          
          # Load basic attributes - will be expanded manually
          include_attrs = [:definition, :prefLabel, :inScheme, :subject, :isEvokedBy, :lexicalizedSense] if include_attrs.empty?
          
          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          concept_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)
            begin
              uri_str = id.to_s.strip
              next nil if uri_str.empty?
              RDF::URI.new(uri_str)
            rescue => e
              puts "[LexicalConcept] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          return [] if concept_ids.empty?
          
          # Use .find() to query by ID (Goo doesn't allow :id in .where)
          concepts = concept_ids.map do |concept_id|
            LexicalConcept.find(concept_id).in(submission).include(*include_attrs).first
          end.compact
          
          # Manually expand definition and subject for each concept
          concepts.each do |concept|
            expand_concept_attributes(concept, submission)
          end
          
          concepts
        end

        def self.count_in_submission(submission)
          return 0 unless submission
          # WORKAROUND: Count without GRAPH filter because concepts are in malformed graph
          ontolex_type = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
          skos_type_http = "http://www.w3.org/2004/02/skos/core#Concept"
          skos_type_https = "https://www.w3.org/2004/02/skos/core#Concept"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          skos_pref_http = "http://www.w3.org/2004/02/skos/core#prefLabel"
          skos_pref_https = "https://www.w3.org/2004/02/skos/core#prefLabel"
          rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
          dct_title = "http://purl.org/dc/terms/title"
          epr = Goo.sparql_query_client(:main)
          begin
            q = [
              "SELECT (COUNT(DISTINCT ?c) AS ?count) WHERE {",
              "  GRAPH ?g {",  # Changed from GRAPH <#{graph}> to GRAPH ?g
              "    { ?c a <#{ontolex_type}> }",
              "    UNION { ?c a <#{skos_type_http}> }",
              "    UNION { ?c a <#{skos_type_https}> }",
              "    UNION { ?s <#{lc_inv_p}> ?c }",
              "    UNION { ?e <#{evokes_p}> ?c }",
              "    UNION { ?c <#{skos_pref_http}> ?l }",
              "    UNION { ?c <#{skos_pref_https}> ?l }",
              "    UNION { ?c <#{rdfs_label}> ?l }",
              "    UNION { ?c <#{dct_title}> ?l }",
              "    FILTER(isIRI(?c))",
              "  }",
              "}",
            ].join("\n")
            row = epr.query(q).first  # Removed graphs: [graph] parameter
            (row && row[:count]) ? row[:count].to_s.to_i : 0
          rescue StandardError
            0
          end
        end

        def self.list_ids_basic(submission, page, size)
          return [] unless submission
          graph = submission.id
          offset = (page - 1) * size
          ontolex_type = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
          skos_type_http = "http://www.w3.org/2004/02/skos/core#Concept"
          skos_type_https = "https://www.w3.org/2004/02/skos/core#Concept"
          lc_inv_p = "http://www.w3.org/ns/lemon/ontolex#isLexicalizedSenseOf"
          evokes_p = "http://www.w3.org/ns/lemon/ontolex#evokes"
          skos_pref_http = "http://www.w3.org/2004/02/skos/core#prefLabel"
          skos_pref_https = "https://www.w3.org/2004/02/skos/core#prefLabel"
          rdfs_label = "http://www.w3.org/2000/01/rdf-schema#label"
          dct_title = "http://purl.org/dc/terms/title"
          q = [
            "SELECT DISTINCT ?c WHERE {",
            "  GRAPH <#{graph}> {",
            "    { ?c a <#{ontolex_type}> }",
            "    UNION { ?c a <#{skos_type_http}> }",
            "    UNION { ?c a <#{skos_type_https}> }",
            "    UNION { ?s <#{lc_inv_p}> ?c }",
            "    UNION { ?e <#{evokes_p}> ?c }",
            "    UNION { ?c <#{skos_pref_http}> ?l }",
            "    UNION { ?c <#{skos_pref_https}> ?l }",
            "    UNION { ?c <#{rdfs_label}> ?l }",
            "    UNION { ?c <#{dct_title}> ?l }",
            "    FILTER(isIRI(?c))",
            "  }",
            "} ORDER BY ?c LIMIT #{size} OFFSET #{offset}",
          ].join("\n")
          epr = Goo.sparql_query_client(:main)
          rows = []
          begin
            rows = epr.query(q, graphs: [graph])
          rescue StandardError
            rows = []
          end
          rows.map { |r| r[:c].to_s }.select { |s| !s.empty? }
        end

        # Helper class method to expand definition and subject attributes for a concept
        def self.expand_concept_attributes(concept, submission)
          return unless concept
          
          # Expand definitions
          if concept.definition
            concept.definition = Array(concept.definition).map do |d|
              expand_definition_for_concept(d, submission)
            end.compact
          end
          
          # Expand subject
          if concept.subject
            concept.subject = expand_subject_for_concept(concept.subject, submission)
          end
        end

        # Helper class method to expand a Definition object
        def self.expand_definition_for_concept(def_obj, submission)
          # If it's just a URI, query the triplestore to get the properties
          if def_obj.is_a?(RDF::URI) || def_obj.is_a?(String)
            def_uri = RDF::URI.new(def_obj.to_s)
            graph = submission.id
            epr = Goo.sparql_query_client(:main)
            
            begin
              # Query to get language and label - language might be a URI
              q = "SELECT ?language ?label WHERE { GRAPH <#{graph}> { <#{def_uri}> <http://purl.org/dc/terms/language> ?language . <#{def_uri}> <http://www.w3.org/2000/01/rdf-schema#label> ?label . } }"
              results = epr.query(q)
              
              if results && !results.empty?
                row = results.first
                lang_value = row[:language]&.to_s
                # Extract language code from lexvo URI if it's a URI
                if lang_value && lang_value.start_with?('http://lexvo.org/id/iso639')
                  lang_value = lang_value.split('/').last
                end
                
                return {
                  '@id' => def_uri.to_s,
                  'language' => lang_value,
                  'label' => row[:label]&.to_s
                }
              end
            rescue => e
              puts "[LexicalConcept] Error loading definition #{def_uri}: #{e.message}"
            end
          end
          
          # Fallback: return the URI
          def_obj.to_s
        end

        # Helper class method to expand a SKOS Concept object
        def self.expand_subject_for_concept(subj_obj, submission)
          # If it's just a URI, query the triplestore to get the properties
          if subj_obj.is_a?(RDF::URI) || subj_obj.is_a?(String)
            subj_uri = RDF::URI.new(subj_obj.to_s)
            graph = submission.id
            epr = Goo.sparql_query_client(:main)
            
            begin
              q = "SELECT ?prefLabel ?broader WHERE { GRAPH <#{graph}> { <#{subj_uri}> <http://www.w3.org/2004/02/skos/core#prefLabel> ?prefLabel . OPTIONAL { <#{subj_uri}> <http://www.w3.org/2004/02/skos/core#broader> ?broader . } } }"
              results = epr.query(q)
              
              if results && !results.empty?
                row = results.first
                result = {
                  '@id' => subj_uri.to_s,
                  'prefLabel' => row[:prefLabel]&.to_s
                }
                result['broader'] = row[:broader]&.to_s if row[:broader]
                
                # Query for narrower concepts
                q_narrower = "SELECT ?narrower WHERE { GRAPH <#{graph}> { <#{subj_uri}> <http://www.w3.org/2004/02/skos/core#narrower> ?narrower . } }"
                narrower_results = epr.query(q_narrower)
                if narrower_results && !narrower_results.empty?
                  result['narrower'] = narrower_results.map { |r| r[:narrower]&.to_s }.compact
                end
                
                return result
              end
            rescue => e
              puts "[LexicalConcept] Error loading subject #{subj_uri}: #{e.message}"
            end
          end
          
          # Fallback: return the URI
          subj_obj.to_s
        end

        private

      end
    end
  end
end
