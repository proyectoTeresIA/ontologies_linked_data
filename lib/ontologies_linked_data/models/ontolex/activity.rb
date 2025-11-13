module LinkedData
  module Models
    module OntoLex
      # Activity entity (prov:Activity)
      # Used for tracking creation, modification, etc.
      class Activity < LinkedData::Models::Base
        model :activity, name_with: :id, collection: :submission,
                         namespace: :prov, schemaless: :true,
                         rdf_type: ->(*_x) { Goo.vocabulary(:prov)['Activity'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :label, namespace: :rdfs
        attribute :endedAtTime, namespace: :prov
        attribute :hasDerivation, namespace: :prov, range: -> { LinkedData::Models::OntoLex::Agent }
        attribute :influenced, namespace: :prov, enforce: [:list]

        serialize_default :label, :endedAtTime, :hasDerivation, :influenced
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
