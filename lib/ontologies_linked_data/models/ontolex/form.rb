module LinkedData
  module Models
    module OntoLex
      class Form < LinkedData::Models::Base
        model :form, name_with: :id, collection: :submission,
                     namespace: :ontolex, schemaless: :true,
                     rdf_type: ->(*_x) { Goo.vocabulary(:ontolex)['Form'] }

        attribute :writtenRep, namespace: :ontolex
        attribute :language, namespace: :dcterms
        attribute :gender, namespace: :lexinfo, property: :gender
        attribute :number, namespace: :lexinfo, property: :number
        attribute :signedForm, namespace: :etv, range: -> { LinkedData::Models::OntoLex::SignedForm }
        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata

        serialize_default :writtenRep, :gender, :number, :signedForm,
                          :lemma, :partOfSpeech, :subject, :subjectLabel, :lexicalEntries
        serialize_never :submission
        serialize_methods :properties, :computed
        links_load submission: [ontology: [:acronym]]

        # Virtual attributes for search enrichment
        attr_reader :lemma, :partOfSpeech, :subject, :subjectLabel, :lexicalEntries

        def lemma=(value, _options = {})
          @lemma = value
        end

        def partOfSpeech=(value, _options = {})
          @partOfSpeech = value
        end

        def subject=(value, _options = {})
          @subject = value
        end

        def subjectLabel=(value, _options = {})
          @subjectLabel = value
        end

        def lexicalEntries=(value, _options = {})
          @lexicalEntries = value
        end

        link_to LinkedData::Hypermedia::Link.new('self', lambda { |s|
          "ontologies/#{s.submission.ontology.acronym}/forms/#{CGI.escape(s.id.to_s)}"
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

        # Generate Solr document for indexing
        def index_doc(to_set = nil)
          return nil unless id && submission

          doc = {
            id: id.to_s,
            resource_id: id.to_s,
            submissionAcronym: submission.ontology.acronym,
            ontologyId: submission.id.to_s
          }

          # Basic form attributes
          doc[:writtenRep] = writtenRep if writtenRep
          doc[:writtenRepExact] = writtenRep if writtenRep

          # Language: extract fragment from URI (e.g., "cat" from "http://lexvo.org/id/iso639-3/cat")
          if language && !language.to_s.empty?
            doc[:language] = language.to_s.split('/').last
          else
          end

          doc[:gender] = gender.to_s.split('/').last if gender
          doc[:number] = number.to_s.split('/').last if number

          # Find all LexicalEntries that reference this form
          begin
            entries = LexicalEntry.in(submission)
                                  .include(:lemma, :partOfSpeech, :evokes, :canonicalForm, :form, :otherForm, :language)
                                  .all
                                  .select { |e| form_referenced_by_entry?(e) }

            if entries.any?
              # If Form doesn't have language, try to get it from the first entry
              unless doc[:language]
                entry_lang = entries.first.language
                doc[:language] = entry_lang.to_s.split('/').last if entry_lang && !entry_lang.to_s.empty?
              end

              # Add lemmas from entries
              lemmas = entries.map(&:lemma).compact.uniq
              doc[:lemma] = lemmas.first if lemmas.any?
              doc[:lemmaExact] = lemmas.first if lemmas.any?

              # Add parts of speech (URI and label)
              pos_values = entries.map { |e| e.partOfSpeech.to_s.split('/').last if e.partOfSpeech }.compact.uniq
              if pos_values.any?
                doc[:partOfSpeech] = pos_values.first
                # Also store simple label for easier filtering (e.g., "noun" from "lexinfo#noun")
                doc[:partOfSpeechLabel] = pos_values.first.split('#').last if pos_values.first.include?('#')
              end

              # Get subjects from evoked concepts
              subject_uris = []
              subject_labels = []

              entries.each do |entry|
                next unless entry.evokes

                evokes_id = entry.evokes.is_a?(Array) ? entry.evokes.first : entry.evokes
                next unless evokes_id

                # Load the concept with its subject
                concept = LexicalConcept.find(evokes_id).in(submission).include(:subject).first
                next unless concept&.subject

                subjects = concept.subject.is_a?(Array) ? concept.subject : [concept.subject]
                subjects.each do |subj_uri|
                  subject_uris << subj_uri.to_s

                  # Try to get label from the LexicalConcept>subject>prefLabel
                  subj_concept = Class.find(subj_uri).in(submission).include(:prefLabel).first
                  subject_labels << subj_concept.prefLabel if subj_concept&.prefLabel
                end
              end

              doc[:subject] = subject_uris.uniq if subject_uris.any?
              doc[:subjectLabel] = subject_labels.uniq if subject_labels.any?

              # Store entry IDs for reference
              doc[:lexicalEntries] = entries.map { |e| e.id.to_s }
            end
          rescue StandardError => e
            puts "[Form.index_doc] Error enriching form #{id}: #{e.message}"
          end

          # Suggest fields for autocomplete
          if writtenRep
            doc[:writtenRepSuggestEdge] = writtenRep
            doc[:writtenRepSuggestNgram] = writtenRep
          end
          if doc[:lemma]
            doc[:lemmaSuggestEdge] = doc[:lemma]
            doc[:lemmaSuggestNgram] = doc[:lemma]
          end

          doc
        end

        # Route searches to the lexical backend (Solr core)
        def self.search(q, params = {})
          super(q, params, :lexical)
        end

        private

        def form_referenced_by_entry?(entry)
          return false unless entry

          # Check canonicalForm
          return true if entry.canonicalForm&.to_s == id.to_s

          # Check otherForm
          if entry.otherForm
            other_forms = entry.otherForm.is_a?(Array) ? entry.otherForm : [entry.otherForm]
            return true if other_forms.any? { |f| f.to_s == id.to_s }
          end

          # Check form array
          if entry.form
            forms = entry.form.is_a?(Array) ? entry.form : [entry.form]
            return true if forms.any? { |f| f.to_s == id.to_s }
          end

          false
        end

        def self.list_for_ids(submission, ids, include_attrs = [])
          return [] unless submission && ids && !ids.empty?

          include_attrs = %i[writtenRep language gender number signedForm] if include_attrs.empty?

          # Convert IDs to RDF::URI if needed, ensuring valid URIs
          form_ids = ids.map do |id|
            next id if id.is_a?(RDF::URI)

            begin
              uri_str = id.to_s.strip
              # Ensure the URI is valid
              next nil if uri_str.empty?

              RDF::URI.new(uri_str)
            rescue StandardError => e
              puts "[Form] Failed to create RDF::URI from: #{id.inspect} - #{e.message}"
              nil
            end
          end.compact
          return [] if form_ids.empty?

          # Query each ID individually and collect results
          forms = form_ids.map do |uri|
            Form.find(uri).in(submission).include(*include_attrs).first
          end.compact

          # Expand signed forms
          forms.each { |f| expand_form_attributes(f, submission) }
          forms
        end

        def self.list_in_submission(submission, page, size, include_attrs = [])
          return [] unless submission

          # Now using standard Goo patterns with properly persisted data
          include_attrs = %i[writtenRep language gender number signedForm] if include_attrs.empty?

          forms = Form.in(submission).include(*include_attrs).page(page, size).all

          # Expand signed forms
          forms.each { |f| expand_form_attributes(f, submission) }
          forms
        end

        # Expand signedForm attributes
        def self.expand_form_attributes(form, submission)
          return unless form && form.signedForm

          form.signedForm = expand_signed_form(form.signedForm, submission)
        end

        # Helper to expand SignedForm (which contains Video)
        def self.expand_signed_form(sf_obj, submission)
          result = LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(
            sf_obj, submission, 'SignedForm', %w[signedRep]
          )
          # Expand nested signedRep (Video)
          if result.is_a?(Hash) && result['signedRep']
            videos = Array(result['signedRep']).map { |v| expand_video(v, submission) }
            result['signedRep'] = videos.size == 1 ? videos.first : videos
          end
          result
        end

        # Helper to expand Video
        def self.expand_video(video_obj, submission)
          LinkedData::Models::OntoLex::LexicalConcept.expand_auxiliary_entity(
            video_obj, submission, 'Video', %w[url]
          )
        end

        def self.count_in_submission(submission)
          return 0 unless submission

          begin
            Form.in(submission).count
          rescue StandardError => e
            puts "[Form] Error counting: #{e.message}"
            0
          end
        end
      end
    end
  end
end
