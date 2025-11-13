module LinkedData
  module Models
    module OntoLex
      class LexicalConcept < LinkedData::Models::Base
        model :lexical_concept, name_with: :id, collection: :submission,
                                namespace: :ontolex, schemaless: :true,
                                rdf_type: ->(*_x) { Goo.vocabulary(:ontolex)['LexicalConcept'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :definition, namespace: :skos, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Definition }
        attribute :note, namespace: :skos, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Note }
        attribute :prefLabel, namespace: :skos
        attribute :inScheme, namespace: :skos
        attribute :subject, namespace: :dcterms, range: -> { LinkedData::Models::Class }
        attribute :isEvokedBy, namespace: :ontolex, enforce: [:list]
        attribute :lexicalizedSense, namespace: :ontolex, property: :lexicalizedSense, enforce: [:list], range: lambda {
          LinkedData::Models::OntoLex::LexicalSense
        }
        attribute :source, namespace: :dcterms

        # Semantic relations within the same resource
        attribute :broader, namespace: :skos, enforce: [:list]
        attribute :narrower, namespace: :skos, enforce: [:list]
        attribute :related, namespace: :skos, enforce: [:list]

        # Mapping relations to other resources
        attribute :mappingRelation, namespace: :skos, enforce: [:list]
        attribute :broadMatch, namespace: :skos, enforce: [:list]
        attribute :closeMatch, namespace: :skos, enforce: [:list]
        attribute :exactMatch, namespace: :skos, enforce: [:list]
        attribute :narrowMatch, namespace: :skos, enforce: [:list]
        attribute :relatedMatch, namespace: :skos, enforce: [:list]

        # Other semantic relations
        attribute :differentFrom, namespace: :owl, enforce: [:list]
        attribute :antonym, namespace: :lexinfo, enforce: [:list]
        attribute :isPartOf, namespace: :dcterms, enforce: [:list]
        attribute :hasPart, namespace: :dcterms, enforce: [:list]

        # Domain-specific relations
        attribute :capital, namespace: :dbo, enforce: [:list]
        attribute :currency, namespace: :dbo, enforce: [:list]
        attribute :causedBy, namespace: :dbo, enforce: [:list]
        attribute :precedesInTime, namespace: :rico, enforce: [:list]
        attribute :followsInTime, namespace: :rico, enforce: [:list]
        attribute :hasLocation, namespace: :dul, enforce: [:list]

        serialize_default :definition, :note, :prefLabel, :inScheme, :subject, :isEvokedBy, :lexicalizedSense, :source,
                          :broader, :narrower, :related,
                          :mappingRelation, :broadMatch, :closeMatch, :exactMatch, :narrowMatch, :relatedMatch,
                          :differentFrom, :antonym, :isPartOf, :hasPart,
                          :capital, :currency, :causedBy, :precedesInTime, :followsInTime, :hasLocation
        serialize_never :submission
        serialize_methods :properties

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        # IMPORTANT: Methods that depend on the existence of entities should return values only after all parsing is complete
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', lambda { |s|
          "ontologies/#{s.submission.ontology.acronym}/lexical_concepts/#{CGI.escape(s.id.to_s)}"
        }, uri_type),
                LinkedData::Hypermedia::Link.new('ontology', lambda { |s|
                  "ontologies/#{s.submission.ontology.acronym}"
                }, Goo.vocabulary['Ontology'])

        def properties
          unmapped
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission

          # Load basic attributes - will be expanded manually
          if include_attrs.empty?
            include_attrs = %i[definition prefLabel inScheme subject isEvokedBy
                               lexicalizedSense note]
          end

          # Use standard Goo query with .in(submission) to filter by graph
          concepts = LexicalConcept.in(submission).include(*include_attrs).page(page, size).all

          # Manually expand definition, subject, and notes for each concept
          concepts.each do |concept|
            expand_concept_attributes(concept, submission)
          end

          concepts
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?

          # Load basic attributes - will be expanded manually
          if include_attrs.empty?
            include_attrs = %i[definition prefLabel inScheme subject isEvokedBy
                               lexicalizedSense note]
          end

          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          concept_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)

            begin
              uri_str = id.to_s.strip
              next nil if uri_str.empty?

              RDF::URI.new(uri_str)
            rescue StandardError => e
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

          begin
            LexicalConcept.in(submission).count
          rescue StandardError => e
            puts "[LexicalConcept] Error counting: #{e.message}"
            0
          end
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

          # Expand notes
          if concept.note
            concept.note = Array(concept.note).map do |n|
              expand_note(n, submission)
            end.compact
          end

          # Expand subject
          return unless concept.subject

          concept.subject = expand_subject_for_concept(concept.subject, submission)
        end

        # Helper class method to expand a Definition object
        def self.expand_definition_for_concept(def_obj, submission)
          result = expand_auxiliary_entity(def_obj, submission, 'Definition', %w[language value wasDerivedFrom])
          result
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
            rescue StandardError => e
              puts "[LexicalConcept] Error loading subject #{subj_uri}: #{e.message}"
            end
          end

          # Fallback: return the URI
          subj_obj.to_s
        end

        # Helper method to expand a Note object
        def self.expand_note(note_obj, submission)
          return expand_auxiliary_entity(note_obj, submission, 'Note', %w[label language value wasDerivedFrom], expand_refs: true)
        end

        # Helper method to expand a Reference object (prov:Entity)
        def self.expand_reference(ref_obj, submission)
          return expand_auxiliary_entity(ref_obj, submission, 'Reference', %w[label value hasDerivation], expand_refs: false)
        end

        # Helper method to expand an Activity object
        def self.expand_activity(activity_obj, submission)
          result = expand_auxiliary_entity(activity_obj, submission, 'Activity', %w[label endedAtTime hasDerivation influenced], expand_refs: false)
          # Expand nested hasDerivation (Agent) - can be single or array
          if result.is_a?(Hash) && result['hasDerivation']
            agents = Array(result['hasDerivation']).map { |agent| expand_agent(agent, submission) }
            result['hasDerivation'] = agents.size == 1 ? agents.first : agents
          end
          result
        end

        # Helper method to expand an Agent object
        def self.expand_agent(agent_obj, submission)
          return expand_auxiliary_entity(agent_obj, submission, 'Agent', %w[name mbox wasAssociatedFor], expand_refs: false)
        end

        # Generic helper to expand any auxiliary entity
        def self.expand_auxiliary_entity(obj, submission, entity_type, fields, expand_refs: true)
          if obj.is_a?(RDF::URI) || obj.is_a?(String)
            uri = RDF::URI.new(obj.to_s)
            graph = submission.id
            epr = Goo.sparql_query_client(:main)

            begin
              # Build dynamic SPARQL query for requested fields
              field_patterns = fields.map do |field|
                ns_map = {
                  'label' => 'http://www.w3.org/2000/01/rdf-schema#label',
                  'value' => 'http://www.w3.org/1999/02/22-rdf-syntax-ns#value',
                  'language' => 'http://purl.org/dc/terms/language',
                  'source' => 'http://purl.org/dc/terms/source',
                  'wasDerivedFrom' => 'http://www.w3.org/ns/prov#wasDerivedFrom',
                  'hasDerivation' => 'http://www.w3.org/ns/prov#hasDerivation',
                  'endedAtTime' => 'http://www.w3.org/ns/prov#endedAtTime',
                  'influenced' => 'http://www.w3.org/ns/prov#influenced',
                  'name' => 'http://xmlns.com/foaf/0.1/name',
                  'mbox' => 'http://xmlns.com/foaf/0.1/mbox',
                  'wasAssociatedFor' => 'http://www.w3.org/ns/prov#wasAssociatedFor',
                  'signedRep' => 'https://w3id.org/def/easytv#signedRep',
                  'url' => 'https://w3id.org/def/easytv#url'
                }
                pred = ns_map[field] || field
                "OPTIONAL { <#{uri}> <#{pred}> ?#{field} . }"
              end.join(' ')

              q = "SELECT #{fields.map { |f| "?#{f}" }.join(' ')} WHERE { GRAPH <#{graph}> { #{field_patterns} } }"
              results = epr.query(q)

              if results && !results.empty?
                # Collect all values for multi-valued fields
                result = { '@id' => uri.to_s }
                
                fields.each do |field|
                  # Collect all values for this field across all result rows
                  all_vals = results.map { |r| r[field.to_sym] }.compact.uniq
                  next if all_vals.empty?

                  # Handle language URIs (lexvo)
                  if field == 'language' && all_vals.first.to_s.start_with?('http://lexvo.org/id/iso639')
                    result[field] = all_vals.map { |v| v.to_s.split('/').last }.first
                  elsif %w[wasDerivedFrom hasDerivation influenced wasAssociatedFor source].include?(field)
                    # These can be multi-valued
                    result[field] = all_vals.size > 1 ? all_vals.map(&:to_s) : all_vals.first.to_s
                  else
                    result[field] = all_vals.first.to_s
                  end
                end

                # Recursively expand wasDerivedFrom references only if requested
                if expand_refs && result['wasDerivedFrom']
                  refs = Array(result['wasDerivedFrom']).map { |ref| expand_auxiliary_entity(ref, submission, 'Reference', %w[label value hasDerivation], expand_refs: false) }
                  result['wasDerivedFrom'] = refs.size == 1 ? refs.first : refs
                end

                # Recursively expand source references (for UsageExample and Usage) only if requested
                if expand_refs && result['source']
                  sources = Array(result['source']).map { |src| expand_auxiliary_entity(src, submission, 'Reference', %w[label value hasDerivation], expand_refs: false) }
                  result['source'] = sources.size == 1 ? sources.first : sources
                end

                return result
              end
            rescue StandardError => e
              puts "[LexicalConcept] Error loading #{entity_type} #{uri}: #{e.message}"
            end
          end

          # Fallback: return the URI
          obj.to_s
        end

        private
      end
    end
  end
end
