module LinkedData
  module Models
    module OntoLex
      class Note < LinkedData::Models::Base
        model :note, name_with: :id, collection: :submission,
                     namespace: :termlex, schemaless: :true,
                     rdf_type: ->(*_x) { Goo.vocabulary(:termlex)['Note'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :label, namespace: :rdfs
        attribute :language, namespace: :dcterms
        attribute :value, namespace: :rdf, property: :value
        attribute :wasDerivedFrom, namespace: :prov, enforce: [:list], range: -> { LinkedData::Models::OntoLex::Reference }

        serialize_default :label, :language, :value, :wasDerivedFrom
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
