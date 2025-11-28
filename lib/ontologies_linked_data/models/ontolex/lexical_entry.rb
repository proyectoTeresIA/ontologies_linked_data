module LinkedData
  module Models
    module OntoLex
      class LexicalEntry < LinkedData::Models::Base
        model :lexical_entry, name_with: :id, collection: :submission,
                              namespace: :ontolex, schemaless: :true,
                              rdf_type: ->(*_x) { Goo.vocabulary(:ontolex)['LexicalEntry'] }

        attribute :lemma, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :partOfSpeech, namespace: :lexinfo
        attribute :termType, namespace: :lexinfo, property: :termType
        # Use the actual predicate from the TTL files
        attribute :form, namespace: :ontolex, enforce: [:list], property: :lexicalForm
        attribute :canonicalForm, namespace: :ontolex
        attribute :otherForm, namespace: :ontolex, enforce: [:list]
        attribute :sense, namespace: :ontolex, enforce: [:list]
        attribute :evokes, namespace: :ontolex, property: :evokes
        # New properties from modelado.md
        attribute :casNumber, namespace: :dbo
        attribute :code, namespace: :dbo
        attribute :hasValency, namespace: :olia, enforce: [:list]
        attribute :signedForm, namespace: :etv, enforce: [:list], range: -> { LinkedData::Models::OntoLex::SignedForm }
        attribute :wasDerivedFrom, namespace: :prov, enforce: [:list], range: lambda {
          LinkedData::Models::OntoLex::Reference
        }
        attribute :wasInfluencedBy, namespace: :prov, enforce: [:list], range: lambda {
          LinkedData::Models::OntoLex::Activity
        }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        # Virtual attributes from Solr (not in RDF, but useful for search results)
        # Custom getters and setters that support Goo's on_load parameter
        attr_reader :subject, :subjectLabel, :writtenRep

        def subject=(value, _options = {})
          @subject = value
        end

        def subjectLabel=(value, _options = {})
          @subjectLabel = value
        end

        def writtenRep=(value, _options = {})
          @writtenRep = value
        end

        # Hypermedia / serialization
        serialize_default :lemma, :language, :partOfSpeech, :termType, :form, :sense, :evokes, :casNumber, :code,
                          :hasValency, :signedForm, :wasDerivedFrom, :wasInfluencedBy, :subject, :subjectLabel, :writtenRep
        serialize_never :submission
        serialize_methods :properties
        links_load submission: [ontology: [:acronym]]
        link_to LinkedData::Hypermedia::Link.new('self', lambda { |s|
          "ontologies/#{s.submission.ontology.acronym}/lexical_entries/#{CGI.escape(s.id.to_s)}"
        }, uri_type),
                LinkedData::Hypermedia::Link.new('ontology', lambda { |s|
                  "ontologies/#{s.submission.ontology.acronym}"
                }, Goo.vocabulary['Ontology']),
                LinkedData::Hypermedia::Link.new('mappings', lambda { |s|
                  "ontologies/#{s.submission.ontology.acronym}/lexical_entries/#{CGI.escape(s.id.to_s)}/mappings"
                }, Goo.vocabulary[:metadata]['Mapping'])

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          unmapped
        end

        # Build a stable per-submission Solr id similar to Class/Property
        def index_id
          bring(:submission) if bring?(:submission)
          return nil unless submission

          submission.bring(:submissionId) if submission.bring?(:submissionId)
          submission.bring(:ontology) if submission.bring?(:ontology)
          return nil unless submission.ontology

          submission.ontology.bring(:acronym) if submission.ontology.bring?(:acronym)
          "#{id}_#{submission.ontology.acronym}_#{submission.submissionId}"
        end

        # Compute Solr document for lexical entries
        def index_doc(to_set = nil)
          doc = {}
          # Required fields: stable unique id for this submission and original resource IRI
          # Use a stable per-submission unique id for the Solr document, similar to classes/properties
          doc[:id] = index_id || id.to_s
          doc[:resource_id] = id.to_s
          bring(:submission) if bring?(:submission)
          return doc unless submission

          # Submission/ontology fields
          doc[:ontologyId] = submission.id.to_s
          doc[:submissionAcronym] = submission.ontology.acronym
          doc[:submissionId] = submission.submissionId

          # Core lexical fields (lemma/writtenRep/language/pos/type)
          all_attrs = to_hash

          %i[lemma language partOfSpeech termType].each do |att|
            val = all_attrs[att]
            next if val.nil? || (val.respond_to?(:empty?) && val.empty?)

            if val.is_a?(Hash)
              # language-tagged hash → index all variants and per-language dynamic
              doc[att] = val.values.flatten
              val.each { |lang, values| doc["#{att}_#{lang}".to_sym] = values }
            else
              doc[att] = Array(val).map(&:to_s)
            end
          end

          # Forms: flatten writtenRep from embedded forms if present
          if form
            reps = []
            Array(form).each do |f|
              reps.concat(Array(f.writtenRep)) if f.respond_to?(:writtenRep) && f.writtenRep
            end
            reps.uniq!
            doc[:writtenRep] = reps unless reps.empty?
          end

          # Senses: definitions/examples, concept labels, and subjects/domains
          if sense
            defs = []
            exs = []
            concepts = []
            concept_labels = []
            subjects = []
            subject_labels = []

            Array(sense).each do |s|
              defs.concat(Array(s.definition)) if s.respond_to?(:definition) && s.definition
              exs.concat(Array(s.example)) if s.respond_to?(:example) && s.example
              next unless s.respond_to?(:lexicalConcept) && s.lexicalConcept

              Array(s.lexicalConcept).each do |lc|
                concepts << lc.id.to_s
                concept_labels.concat(Array(lc.prefLabel)) if lc.respond_to?(:prefLabel) && lc.prefLabel

                # Extract subjects/domains from the lexical concept
                next unless lc.respond_to?(:subject) && lc.subject

                Array(lc.subject).each do |subj|
                  if subj.is_a?(Hash)
                    # Already expanded subject with prefLabel
                    subjects << subj['@id'] if subj['@id']
                    subject_labels << subj['prefLabel'] if subj['prefLabel']
                  elsif subj.respond_to?(:id)
                    # Goo resource
                    subjects << subj.id.to_s
                    subject_labels << subj.prefLabel if subj.respond_to?(:prefLabel) && subj.prefLabel
                  else
                    # URI string
                    subjects << subj.to_s
                  end
                end
              end
            end

            doc[:definition] = defs unless defs.empty?
            doc[:example] = exs unless exs.empty?
            doc[:concept] = concepts.uniq unless concepts.empty?
            doc[:conceptLabel] = concept_labels.uniq unless concept_labels.empty?
            doc[:subject] = subjects.uniq unless subjects.empty?
            doc[:subjectLabel] = subject_labels.uniq unless subject_labels.empty?
          end

          # Concepts directly evoked by the entry (ensure they are indexed even without senses)
          begin
            evoked_ids = respond_to?(:evokes_ids) ? Array(evokes_ids) : []
            doc[:concept] = (Array(doc[:concept]) + evoked_ids).uniq unless evoked_ids.empty?
          rescue StandardError
          end

          # Raw properties if needed
          props = properties_for_indexing
          if props
            doc[:property] = props[:property]
            doc[:propertyRaw] = props[:propertyRaw]
          end

          doc
        end

        def properties_for_indexing
          self_props = properties
          return nil if self_props.nil?

          props = {}
          prop_vals = []
          self_props.each do |attr_key, attr_val|
            if attr_val.is_a?(Array)
              props[attr_key] = []
              attr_val.uniq.each do |val|
                real = val.is_a?(Goo::Base::Resource) ? val.id.to_s : val.to_s.strip
                next if real.respond_to?(:empty?) && real.empty?

                prop_vals << real
                props[attr_key] << real
              end
            else
              real = attr_val.to_s.strip
              next if real.respond_to?(:empty?) && real.empty?

              prop_vals << real
              props[attr_key] = real
            end
          end

          begin
            { propertyRaw: MultiJson.dump(props), property: prop_vals.uniq }
          rescue JSON::GeneratorError
            nil
          end
        end

        # Route searches to the lexical backend (Solr core)
        def self.search(q, params = {})
          super(q, params, :lexical)
        end

        # Standard serialization - Goo handles everything now
        def to_hash(*)
          super()
        end

        # Class-level helpers
        def self.count_in_submission(submission)
          return 0 unless submission

          begin
            LexicalEntry.in(submission).count
          rescue StandardError => e
            puts "[LexicalEntry] Error counting: #{e.message}"
            0
          end
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission

          if include_attrs.empty?
            include_attrs = %i[lemma language partOfSpeech form sense evokes signedForm wasDerivedFrom
                               wasInfluencedBy]
          end
          entries = LexicalEntry.in(submission).include(*include_attrs).page(page, size).all

          # Expand provenance attributes
          entries.each { |e| expand_entry_attributes(e, submission) }
          entries
        end

        # Build enriched read_only entries for specific IRIs (parity with list endpoint)
        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?

          if include_attrs.empty?
            include_attrs = %i[lemma language partOfSpeech form sense evokes signedForm wasDerivedFrom
                               wasInfluencedBy]
          end

          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          entry_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)

            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?

              RDF::URI.new(uri_str)
            rescue StandardError => e
              puts "[LexicalEntry] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact

          return [] if entry_ids.empty?

          # Query each ID individually and collect results
          entries = entry_ids.map do |uri|
            LexicalEntry.find(uri).in(submission).include(*include_attrs).first
          end.compact

          # Expand provenance attributes
          entries.each { |e| expand_entry_attributes(e, submission) }
          entries
        end

        # Expand provenance attributes for an entry
        def self.expand_entry_attributes(entry, submission)
          return unless entry

          # Expand wasDerivedFrom (References) - only if loaded
          if entry.loaded_attributes.include?(:wasDerivedFrom) && entry.wasDerivedFrom
            entry.wasDerivedFrom = Array(entry.wasDerivedFrom).map do |ref|
              LinkedData::Models::OntoLex::LexicalConcept.expand_reference(ref, submission)
            end.compact
          end

          # Expand wasInfluencedBy (Activities) - only if loaded
          if entry.loaded_attributes.include?(:wasInfluencedBy) && entry.wasInfluencedBy
            entry.wasInfluencedBy = Array(entry.wasInfluencedBy).map do |activity|
              LinkedData::Models::OntoLex::LexicalConcept.expand_activity(activity, submission)
            end.compact
          end

          # Expand signedForm (SignedForm with Video) - only if loaded
          return unless entry.loaded_attributes.include?(:signedForm) && entry.signedForm

          entry.signedForm = Array(entry.signedForm).map do |sf|
            result = LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(sf, submission,
                                                                                         'SignedForm', %w[signedRep])
            # Expand nested video
            if result.is_a?(Hash) && result['signedRep']
              videos = Array(result['signedRep']).map do |vid|
                LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(vid, submission, 'Video', %w[url])
              end
              result['signedRep'] = videos.size == 1 ? videos.first : videos
            end
            result
          end.compact
        end
      end
    end
  end
end
