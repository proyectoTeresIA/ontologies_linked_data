module LinkedData
  module Models
    module OntoLex
      class UsageExample < LinkedData::Models::Base
        model :usage_example, name_with: :id, collection: :submission,
                              namespace: :lexicog, schemaless: :true,
                              rdf_type: ->(*_x) { Goo.vocabulary(:lexicog)['UsageExample'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :language, namespace: :dcterms
        attribute :value, namespace: :rdf, property: :value
        attribute :source, namespace: :dcterms, range: -> { LinkedData::Models::OntoLex::Reference }

        serialize_default :language, :value, :source
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
