require_relative '../test_case'

class TestOntoLexParser < LinkedData::TestCase
  def test_parse_simple_ttl_into_models
    # Arrange: create ontology + submission and point to the provided TTL
    ont_count = 1
    acronym = 'ONTOLEX'
    file_path = File.expand_path('../data/ontolex/sample.ttl', __dir__)

    delete_ontologies_and_submissions
    # Create minimal ontology + submission
    u, of, contact = ontology_objects
    ont = LinkedData::Models::Ontology.new(acronym: acronym, name: "#{acronym} Ontology", administeredBy: [u])
    ont.summaryOnly = true
    ont.save
    sub = LinkedData::Models::OntologySubmission.new(
      ontology: ont,
      hasOntologyLanguage: of,
      submissionId: 1,
      contact: [contact],
      released: DateTime.now - 1,
      definitionProperty: RDF::IRI.new("http://bioontology.org/ontologies/biositemap.owl#definition")
    )
    sub.save
    sub.pullLocation = RDF::IRI.new("file://#{file_path}")
    sub.save

    # Act: parse
    result = LinkedData::Parser::OntoLex.parse(file_path.to_s, sub)

    # Assert: basic presence
    refute_nil result
    assert result[:entries].is_a?(Array)
    assert result[:senses].is_a?(Hash)
    assert result[:concepts].is_a?(Array)
    assert result[:forms].is_a?(Hash)

    # This fixture defines exactly one entry, one sense, one concept, one form
    assert_equal 1, result[:entries].length
    assert_equal 1, result[:concepts].length
    assert_equal 1, result[:senses].length
    assert_equal 1, result[:forms].length

    # Verify relationships
    entry = result[:entries].first
    # entry should link to its canonical form and sense
    refute_nil entry.form
    assert entry.form.is_a?(Array)
    assert_equal 1, entry.form.length
    refute_nil entry.sense
    assert entry.sense.is_a?(Array)
    assert_equal 1, entry.sense.length

    form = entry.form.first
    sense = entry.sense.first
    concept = result[:concepts].first

    # writtenRep of form is "test"@en in the NT fixture; model stores text, language separate
    assert_equal 'test', form.writtenRep.to_s
    assert form.language.is_a?(Array)
    assert_includes form.language, 'en'

    # sense -> concept via isLexicalizedSenseOf mapping
    assert_equal [concept.id], sense.lexicalConcept

    # concept has prefLabel and definition; accept with or without '@en'
    pref = concept.prefLabel.is_a?(Array) ? concept.prefLabel.first : concept.prefLabel
    assert_includes ['Test concept', 'Test concept@en'], pref.to_s
    defn_vals = concept.definition.is_a?(Array) ? concept.definition : [concept.definition]
    assert defn_vals.compact.map(&:to_s).any? { |v| v == 'A simple concept' || v == 'A simple concept@en' }
  end
end
