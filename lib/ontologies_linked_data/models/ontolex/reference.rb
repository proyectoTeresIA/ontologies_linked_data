module LinkedData
  module Models
    module OntoLex
      # Generic reference entity (prov:Entity)
      # Used for bibliographic references, sources, etc.
      class Reference < LinkedData::Models::Base
        model :reference, name_with: :id, collection: :submission,
                          namespace: :prov, schemaless: :true,
                          rdf_type: ->(*_x) { Goo.vocabulary(:prov)['Entity'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :label, namespace: :rdfs
        attribute :value, namespace: :rdf, property: :value
        attribute :hasDerivation, namespace: :prov, enforce: [:list]

        serialize_default :label, :value, :hasDerivation
        serialize_never :submission

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def to_hash(options = {})
          hash = super(options)
          # Ensure hasDerivation is always an array in the output
          hash[:hasDerivation] = [hash[:hasDerivation]] if hash[:hasDerivation] && !hash[:hasDerivation].is_a?(Array)
          hash
        end
      end
    end
  end
end
