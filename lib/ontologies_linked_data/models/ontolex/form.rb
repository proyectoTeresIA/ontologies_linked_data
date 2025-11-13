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

        serialize_default :writtenRep, :gender, :number, :signedForm
        serialize_never :submission
        serialize_methods :properties, :computed

        link_to LinkedData::Hypermedia::Link.new('self', lambda { |s|
          "ontologies/#{s.submission.ontology.acronym}/forms/#{CGI.escape(s.id.to_s)}"
        }, uri_type)

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def properties
          unmapped
        end

        def to_hash(options = {})
          super(options)
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
