module LinkedData
  module Models
    module OntoLex
      class SignedForm < LinkedData::Models::Base
        model :signed_form, name_with: :id, collection: :submission,
                            namespace: :etv, schemaless: :true,
                            rdf_type: ->(*_x) { Goo.vocabulary(:etv)['signedForm'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :signedRep, namespace: :etv, range: -> { LinkedData::Models::OntoLex::Video }

        serialize_default :signedRep
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
