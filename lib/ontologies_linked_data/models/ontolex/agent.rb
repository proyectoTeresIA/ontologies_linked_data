module LinkedData
  module Models
    module OntoLex
      # Agent entity (prov:Agent)
      # Used for tracking who created/modified resources
      class Agent < LinkedData::Models::Base
        model :agent, name_with: :id, collection: :submission,
                      namespace: :prov, schemaless: :true,
                      rdf_type: ->(*_x) { Goo.vocabulary(:prov)['Agent'] }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :name, namespace: :foaf
        attribute :mbox, namespace: :foaf
        attribute :wasAssociatedFor, namespace: :prov, enforce: [:list]

        serialize_default :name, :mbox, :wasAssociatedFor
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
