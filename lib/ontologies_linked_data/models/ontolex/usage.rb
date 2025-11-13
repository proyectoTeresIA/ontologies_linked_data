module LinkedData
  module Models
    module OntoLex
      class Usage < LinkedData::Models::Base
        model :usage, name_with: :id, collection: :submission,
                      namespace: :termlex, schemaless: :true,
                      rdf_type: ->(*_x) { Goo.vocabulary(:termlex)['Usage'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :language, namespace: :dcterms
        attribute :value, namespace: :rdf, property: :value
        attribute :source, namespace: :dcterms, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Reference }

        serialize_default :language, :value, :source
        serialize_never :submission

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def to_hash(options = {})
          hash = super(options)
          # Ensure source is always an array in the output
          hash[:source] = [hash[:source]] if hash[:source] && !hash[:source].is_a?(Array)
          hash
        end
      end
    end
  end
end
