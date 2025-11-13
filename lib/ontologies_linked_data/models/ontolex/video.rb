module LinkedData
  module Models
    module OntoLex
      class Video < LinkedData::Models::Base
        model :video, name_with: :id, collection: :submission,
                      namespace: :etv, schemaless: :true,
                      rdf_type: ->(*_x) { Goo.vocabulary(:etv)['Video'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :url, namespace: :etv

        serialize_default :url
        serialize_never :submission

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def to_hash(options = {})
          super(options)
        end
      end
    end
  end
end
