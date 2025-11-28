module LinkedData
  module Models
    module OntoLex
      class Definition < LinkedData::Models::Base
        model :definition, name_with: :id, collection: :submission,
                           namespace: :termlex, schemaless: :true,
                           rdf_type: ->(*_x) { Goo.vocabulary(:termlex)['Definition'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :language, namespace: :dcterms
        attribute :value, namespace: :rdf, property: :value
        attribute :label, namespace: :rdfs, property: :label
        attribute :wasDerivedFrom, namespace: :prov, enforce: [:list]

        serialize_default :language, :value, :label, :wasDerivedFrom
        serialize_never :submission

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def to_hash(options = {})
          hash = super(options)
          # Ensure wasDerivedFrom is always an array in the output
          if hash[:wasDerivedFrom] && !hash[:wasDerivedFrom].is_a?(Array)
            hash[:wasDerivedFrom] = [hash[:wasDerivedFrom]]
          end
          hash
        end
      end
    end
  end
end
