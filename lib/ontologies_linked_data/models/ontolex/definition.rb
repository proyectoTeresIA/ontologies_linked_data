module LinkedData
  module Models
    module OntoLex
      class Definition < LinkedData::Models::Base
        model :definition, name_with: :id, collection: :submission,
                          namespace: :termlex, schemaless: :true,
                          rdf_type: ->(*_x) { RDF::URI('http://purl.org/net/nknouf/ns/bibtex#Definition') }

        attribute :submission, collection: ->(s) { s.resource_id }, namespace: :metadata
        attribute :language, namespace: :dcterms
        attribute :label, namespace: :rdfs

        serialize_default :language, :label
        serialize_never :submission

        # Grant access to all users for OntoLex entities
        grant_access_to_all true

        def to_hash
          {
            '@id' => self.id.to_s,
            'language' => self.language.to_s,
            'label' => self.label
          }
        end
      end
    end
  end
end
