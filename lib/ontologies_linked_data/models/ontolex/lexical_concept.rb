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

        serialize_default :definition, :note, :inScheme, :subject, :isEvokedBy, :lexicalizedSense, :source,
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
            include_attrs = %i[definition inScheme subject isEvokedBy
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
            include_attrs = %i[definition inScheme subject isEvokedBy
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

          # Expand inScheme -> ConceptSet -> dct:source -> LexicalConceptualResource
          if concept.inScheme
            expanded_schemes = normalize_to_array(concept.inScheme).map do |scheme|
              expand_in_scheme_for_concept(scheme, submission)
            end.compact

            concept.inScheme = expanded_schemes.length == 1 ? expanded_schemes.first : expanded_schemes
          end

          # Expand subject
          return unless concept.subject

          concept.subject = expand_subject_for_concept(concept.subject, submission)
        end

        # Helper class method to expand a ConceptSet from skos:inScheme
        # and resolve its dct:source (LexicalConceptualResource)
        def self.expand_in_scheme_for_concept(scheme_obj, submission)
          if scheme_obj.is_a?(Hash)
            return scheme_obj if scheme_obj['source']
          end

          scheme_uri_str = extract_uri_from_value(scheme_obj)
          return scheme_obj.to_s unless scheme_uri_str && !scheme_uri_str.empty?

          scheme_data = expand_auxiliary_entity(
            scheme_uri_str,
            submission,
            'ConceptSet',
            %w[source],
            expand_refs: false,
            strict: true
          )

          if !scheme_data.is_a?(Hash) || scheme_data['source'].nil?
            conceptset_uri = find_concept_set_for_scheme(scheme_uri_str, submission)
            if conceptset_uri
              scheme_data = expand_auxiliary_entity(
                conceptset_uri,
                submission,
                'ConceptSet',
                %w[source],
                expand_refs: false,
                strict: true
              )
            end
          end

          if scheme_data.is_a?(Hash) && scheme_data['source']
            scheme_data['source'] = expand_lexical_conceptual_resource(scheme_data['source'], submission)
          elsif scheme_data.is_a?(Hash)
            scheme_data['source'] = expand_lexical_conceptual_resource(scheme_uri_str, submission)
          else
            fallback_source = expand_lexical_conceptual_resource(scheme_uri_str, submission)
            if fallback_source.is_a?(Hash)
              scheme_data = {
                '@id' => scheme_uri_str,
                'source' => fallback_source
              }
            end
          end

          scheme_data
        end

        def self.find_concept_set_for_scheme(scheme_uri, submission)
          graph = submission&.id
          return nil if graph.nil?

          epr = Goo.sparql_query_client(:main)
          concept_set_types = [
            'http://www.w3.org/ns/lemon/ontolex#ConceptSet',
            'https://www.w3.org/ns/lemon/ontolex#ConceptSet'
          ]

          concept_set_types.each do |type_uri|
            query = <<~SPARQL
              SELECT ?conceptSet WHERE {
                GRAPH <#{graph}> {
                  ?conceptSet a <#{type_uri}> .
                  ?conceptSet <http://purl.org/dc/terms/source> <#{scheme_uri}> .
                }
              }
              LIMIT 1
            SPARQL
            results = epr.query(query)
            return results.first[:conceptSet].to_s if results && !results.empty?
          end

          nil
        rescue StandardError => e
          puts "[LexicalConcept] Error resolving ConceptSet for scheme #{scheme_uri}: #{e.message}"
          nil
        end

        def self.extract_uri_from_value(value)
          return nil if value.nil?
          return value.to_s if value.is_a?(RDF::URI) || value.is_a?(String)
          return value.id.to_s if value.respond_to?(:id) && value.id

          if value.is_a?(Hash)
            return value['@id'] if value['@id']
            return value['id'] if value['id']
            return value['uri'] if value['uri']
          end

          if value.is_a?(Array)
            return value[1].to_s if value.length == 2 && value[0].to_s == 'uri'
            return extract_uri_from_value(value.first)
          end

          value.to_s
        end

        def self.normalize_to_array(value)
          return [] if value.nil?
          return value if value.is_a?(Array)

          [value]
        end

        # Expand a Meta-Share LexicalConceptualResource entity referenced from ConceptSet dct:source
        def self.expand_lexical_conceptual_resource(resource_obj, submission)
          return resource_obj.to_s unless resource_obj.is_a?(RDF::URI) || resource_obj.is_a?(String)

          predicate_overrides = {
            'resourceName' => 'http://w3id.org/meta-share/meta-share/2.0.0/resourceName',
            'resourceCreator' => 'http://w3id.org/meta-share/meta-share/2.0.0/resourceCreator',
            'language' => 'http://w3id.org/meta-share/meta-share/2.0.0/language',
            'domain' => 'http://w3id.org/meta-share/meta-share/2.0.0/domain',
            'uri' => 'http://w3id.org/meta-share/meta-share/2.0.0/uri'
          }

          candidates = candidate_resource_uris(resource_obj, submission)
          result = nil

          candidates.each do |candidate_uri|
            result = expand_auxiliary_entity(
              candidate_uri,
              submission,
              'LexicalConceptualResource',
              %w[resourceName uri resourceCreator language domain],
              expand_refs: false,
              predicate_overrides: predicate_overrides,
              multivalued_fields: %w[resourceCreator language domain],
              normalize_language_codes: false,
              strict: true
            )
            break if result.is_a?(Hash) && result['resourceName']
          end

          return resource_obj.to_s unless result

          if result.is_a?(Hash) && result['resourceCreator']
            creators = Array(result['resourceCreator'])
            expanded_creators = creators.map { |creator| expand_actor(creator, submission) }
            result['resourceCreator'] = expanded_creators
          end

          result
        end

        def self.candidate_resource_uris(resource_obj, submission)
          source_uri = resource_obj.to_s
          candidates = [source_uri]

          begin
            uri_match = source_uri.match(%r{\A(https?://[^/]+)(/.*)?\z})
            if uri_match
              base = uri_match[1]
              path = uri_match[2].to_s
              last_segment = path.split('/').reject(&:empty?).last
              candidates << "#{base}/resources/#{last_segment}" if last_segment && !last_segment.empty?
            end
          rescue StandardError
          end

          by_local_name = find_resource_by_local_name(source_uri, submission)
          candidates << by_local_name if by_local_name

          candidates.compact.uniq
        end

        def self.find_resource_by_local_name(source_uri, submission)
          graph = submission&.id
          return nil if graph.nil?

          local_name = source_uri.to_s.split(/[\/#]/).last
          return nil if local_name.nil? || local_name.empty?

          escaped_local_name = local_name.gsub('"', '\\"')
          epr = Goo.sparql_query_client(:main)
          type_uris = [
            'http://w3id.org/meta-share/meta-share/2.0.0/LexicalConceptualResource',
            'http://w3id.org/meta-share/meta-share/LexicalConceptualResource',
            'https://w3id.org/meta-share/meta-share/2.0.0/LexicalConceptualResource',
            'https://w3id.org/meta-share/meta-share/LexicalConceptualResource'
          ]

          type_uris.each do |type_uri|
            query = <<~SPARQL
              SELECT ?res WHERE {
                GRAPH <#{graph}> {
                  ?res a <#{type_uri}> .
                  FILTER(STRENDS(STR(?res), "#{escaped_local_name}"))
                }
              }
              LIMIT 1
            SPARQL

            results = epr.query(query)
            return results.first[:res].to_s if results && !results.empty?
          end

          nil
        rescue StandardError => e
          puts "[LexicalConcept] Error resolving LexicalConceptualResource by local name #{source_uri}: #{e.message}"
          nil
        end

        # Expand Meta-Share Actor label for resourceCreator references
        def self.expand_actor(actor_obj, submission)
          return actor_obj.to_s unless actor_obj.is_a?(RDF::URI) || actor_obj.is_a?(String)

          expand_auxiliary_entity(
            actor_obj,
            submission,
            'Actor',
            %w[label],
            expand_refs: false,
            strict: true
          )
        end

        # Helper class method to expand a Definition object
        def self.expand_definition_for_concept(def_obj, submission)
          expand_auxiliary_entity(def_obj, submission, 'Definition', %w[language value label wasDerivedFrom])
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
          expand_auxiliary_entity(note_obj, submission, 'Note', %w[label language value wasDerivedFrom],
                                  expand_refs: true)
        end

        # Helper method to expand a Reference object (prov:Entity)
        def self.expand_reference(ref_obj, submission)
          expand_auxiliary_entity(ref_obj, submission, 'Reference', %w[label value hasDerivation],
                                  expand_refs: false)
        end

        # Helper method to expand an Activity object
        def self.expand_activity(activity_obj, submission)
          result = expand_auxiliary_entity(activity_obj, submission, 'Activity',
                                           %w[label endedAtTime hasDerivation influenced], expand_refs: false)
          # Expand nested hasDerivation (Agent) - can be single or array
          if result.is_a?(Hash) && result['hasDerivation']
            agents = Array(result['hasDerivation']).map { |agent| expand_agent(agent, submission) }
            result['hasDerivation'] = agents.size == 1 ? agents.first : agents
          end
          result
        end

        # Helper method to expand an Agent object
        def self.expand_agent(agent_obj, submission)
          expand_auxiliary_entity(agent_obj, submission, 'Agent', %w[name mbox wasAssociatedFor],
                                  expand_refs: false)
        end

        # Generic helper to expand any auxiliary entity
        def self.expand_auxiliary_entity(obj, submission, entity_type, fields, expand_refs: true,
                                         predicate_overrides: {}, multivalued_fields: [],
                                         normalize_language_codes: true, strict: false)
          if obj.is_a?(RDF::URI) || obj.is_a?(String)
            uri = RDF::URI.new(obj.to_s)
            graph = submission&.id
            if strict && graph.nil?
              raise ArgumentError, "[LexicalConcept] Missing submission graph while loading #{entity_type} #{uri}"
            end

            return obj.to_s if graph.nil?

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
                pred = predicate_overrides[field] || ns_map[field] || field
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
                  effective_multivalued = %w[wasDerivedFrom hasDerivation influenced wasAssociatedFor source] + multivalued_fields

                  if normalize_language_codes && field == 'language' && all_vals.first.to_s.start_with?('http://lexvo.org/id/iso639')
                    result[field] = all_vals.map { |v| v.to_s.split('/').last }.first
                  elsif effective_multivalued.include?(field)
                    # These can be multi-valued
                    result[field] = all_vals.size > 1 ? all_vals.map(&:to_s) : all_vals.first.to_s
                  else
                    result[field] = all_vals.first.to_s
                  end
                end

                # Recursively expand wasDerivedFrom references only if requested
                if expand_refs && result['wasDerivedFrom']
                  refs = Array(result['wasDerivedFrom']).map do |ref|
                    expand_auxiliary_entity(ref, submission, 'Reference', %w[label value hasDerivation],
                                            expand_refs: false)
                  end
                  result['wasDerivedFrom'] = refs.size == 1 ? refs.first : refs
                end

                # Recursively expand source references (for UsageExample and Usage) only if requested
                if expand_refs && result['source']
                  sources = Array(result['source']).map do |src|
                    expand_auxiliary_entity(src, submission, 'Reference', %w[label value hasDerivation],
                                            expand_refs: false)
                  end
                  result['source'] = sources.size == 1 ? sources.first : sources
                end

                return result
              end
            rescue StandardError => e
              if strict
                raise StandardError, "[LexicalConcept] Error loading #{entity_type} #{uri}: #{e.message}"
              else
                puts "[LexicalConcept] Error loading #{entity_type} #{uri}: #{e.message}"
              end
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
