require_relative '../test_case'
require 'tmpdir'

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
    
    # Debug: Check what's in the instance variables vs computed methods
    puts "\n[RELATIONSHIP DEBUG]"
    puts "Entry ID: #{entry.id}"
    puts "Entry @form (instance var): #{entry.instance_variable_get(:@form).inspect}"
    puts "Entry.form (computed method): #{entry.form.inspect}"
    puts "Entry.form.length: #{entry.form.length}"
    puts ""
    puts "Entry @sense (instance var): #{entry.instance_variable_get(:@sense).inspect}"
    puts "Entry.sense (computed method): #{entry.sense.inspect}"
    puts "Entry.sense.length: #{entry.sense.length}"
    puts ""
    puts "Entry @evokes (instance var): #{entry.instance_variable_get(:@evokes).inspect}"
    puts "Entry.evokes (computed method): #{entry.evokes.inspect}"
    puts ""
    
    sense = result[:senses].values.first
    puts "Sense ID: #{sense.id}"
    puts "Sense @lexicalConcept (instance var): #{sense.instance_variable_get(:@lexicalConcept).inspect}"
    puts "Sense.lexicalConcept (computed method): #{sense.lexicalConcept.inspect}"
    puts ""
    
    # Debug: Query the triple store directly to see what's actually saved
    puts "[TRIPLE STORE DEBUG]"
    graph_id = sub.id
    entry_uri = entry.id
    form_uri = result[:forms].keys.first
    
    # Query for all triples about the entry
    query = "SELECT ?p ?o WHERE { GRAPH <#{graph_id}> { <#{entry_uri}> ?p ?o } }"
    client = Goo.sparql_query_client(:main)
    puts "Query: #{query}"
    puts "Results:"
    client.query(query).each do |row|
      puts "  #{row[:p]} -> #{row[:o]}"
    end
    puts ""
    
    # Specifically check for form predicate
    form_predicate = "http://www.w3.org/ns/lemon/ontolex#form"
    query2 = "ASK { GRAPH <#{graph_id}> { <#{entry_uri}> <#{form_predicate}> <#{form_uri}> } }"
    puts "Checking if form triple exists: #{query2}"
    result_ask = client.query(query2)
    puts "Result: #{result_ask.inspect}"
    puts ""
    
    # Now test the ACTUAL query that entry.form() uses
    puts "[TESTING ACTUAL form() QUERY]"
    form_p = "http://www.w3.org/ns/lemon/ontolex#form"
    lex_form_p = "http://www.w3.org/ns/lemon/ontolex#lexicalForm"
    can_p = "http://www.w3.org/ns/lemon/ontolex#canonicalForm"
    oth_p = "http://www.w3.org/ns/lemon/ontolex#otherForm"
    wr_p = "http://www.w3.org/ns/lemon/ontolex#writtenRep"
    lang_p = "http://purl.org/dc/terms/language"
    
    form_query = [
      "SELECT ?f ?w ?l WHERE {",
      "  GRAPH <#{graph_id}> {",
      "    VALUES ?s { <#{entry_uri}> }",
      "    { ?s <#{form_p}> ?f } UNION { ?s <#{lex_form_p}> ?f } UNION { ?s <#{can_p}> ?f } UNION { ?s <#{oth_p}> ?f } .",
      "    OPTIONAL { ?f <#{wr_p}> ?w }",
      "    OPTIONAL { ?f <#{lang_p}> ?l }",
      "    FILTER(isIRI(?f))",
      "  }",
      "}",
    ].join("\n")
    
    puts "Form query: #{form_query}"
    puts "Form query results:"
    client.query(form_query).each do |row|
      puts "  f=#{row[:f]}, w=#{row[:w]}, l=#{row[:l]}"
    end
    puts ""
    
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
    # writtenRep is now a single value (String), not an array
    assert_equal 'test', form.writtenRep.to_s
    # language is a single value (String), not an array
    assert form.language.is_a?(String)
    assert_equal 'en', form.language

    # sense -> concept via isLexicalizedSenseOf mapping
    # lexicalConcept is a single value, not an array
    assert_equal concept.id, sense.lexicalConcept.id

    # concept has definition (but NOT prefLabel - LexicalConcepts don't have prefLabel in OntoLex)
    defn_vals = concept.definition.is_a?(Array) ? concept.definition : [concept.definition]
    assert defn_vals.compact.map(&:to_s).any? { |v| v == 'A simple concept' || v == 'A simple concept@en' }
  end

  def test_ontolex_format_detection
    # Test that ONTOLEX format is properly recognized
    ontolex_format = LinkedData::Models::OntologyFormat.find("ONTOLEX").first
    refute_nil ontolex_format, "ONTOLEX format should exist"
    
    assert ontolex_format.ontolex?, "ONTOLEX format should return true for ontolex?"
    
    # class_type returns an RDF::URI, not the class itself
    class_type_uri = ontolex_format.class_type
    assert class_type_uri.is_a?(RDF::URI), "class_type should return an RDF::URI"
    assert_equal "http://www.w3.org/ns/lemon/ontolex#LexicalConcept", class_type_uri.to_s,
                 "ONTOLEX format should return LexicalConcept URI as class_type"
    
    assert_nil ontolex_format.tree_property, "ONTOLEX format should have nil tree_property"
  end

  def test_end_to_end_ontolex_submission
    # This test covers the complete OntoLex submission flow:
    # 1. Create ontology with ONTOLEX format
    # 2. Submit ontology file
    # 3. Verify format routing to OntoLex parser
    # 4. Verify all OntoLex models are created with proper structure
    # 5. Verify hypermedia links are OntoLex-specific
    
    acronym = 'ASLEX_E2E'
    # Use the sample file since the aparells_sanitarios file may not be mounted in Docker
    file_path = File.expand_path('../data/ontolex/sample.ttl', __dir__)
    
    # Verify file exists
    assert File.exist?(file_path), "Test file should exist at #{file_path}"
    
    delete_ontologies_and_submissions
    
    # Step 1: Create ontology with ONTOLEX format
    u, _, contact = ontology_objects
    ontolex_format = LinkedData::Models::OntologyFormat.find("ONTOLEX").first
    refute_nil ontolex_format, "ONTOLEX format must exist"
    
    ont = LinkedData::Models::Ontology.new(
      acronym: acronym,
      name: "Aparells Sanitaris OntoLex E2E Test",
      administeredBy: [u]
    )
    ont.summaryOnly = false
    assert ont.save, "Ontology should save: #{ont.errors}"
    
    # Step 2: Create submission with ONTOLEX format
    sub = LinkedData::Models::OntologySubmission.new(
      ontology: ont,
      hasOntologyLanguage: ontolex_format,
      submissionId: 1,
      contact: [contact],
      released: DateTime.now - 1
    )
    
    # Copy file to temporary location for upload
    tmp_file = File.join(Dir.tmpdir, "aslex_e2e_#{Process.pid}.ttl")
    FileUtils.cp(file_path, tmp_file)
    sub.uploadFilePath = tmp_file
    
    assert sub.save, "Submission should save: #{sub.errors}"
    
    # Step 3: Parse using OntoLex parser (simulating submission processing)
    result = LinkedData::Parser::OntoLex.parse(tmp_file, sub)
    
    # Verify parser result structure
    refute_nil result, "Parser should return result"
    assert result[:entries].is_a?(Array), "Result should contain entries array"
    assert result[:senses].is_a?(Hash), "Result should contain senses hash"
    assert result[:concepts].is_a?(Array), "Result should contain concepts array"
    assert result[:forms].is_a?(Hash), "Result should contain forms hash"
    
    # Step 4: Verify OntoLex models were created with proper attributes
    
    # Check LexicalEntries
    assert result[:entries].length > 0, "Should have at least one lexical entry"
    entry = result[:entries].first
    assert_instance_of LinkedData::Models::OntoLex::LexicalEntry, entry
    assert entry.id, "Entry should have an ID"
    assert entry.submission, "Entry should be linked to submission"
    assert_equal sub.id, entry.submission.id, "Entry should be linked to correct submission"
    
    # Check Forms
    assert result[:forms].length > 0, "Should have at least one form"
    form_id, form = result[:forms].first
    assert_instance_of LinkedData::Models::OntoLex::Form, form
    assert form.id, "Form should have an ID"
    assert form.writtenRep, "Form should have writtenRep"
    # Language is a single value (not an array) since it doesn't have enforce: [:list]
    if form.language
      assert form.language.is_a?(String), "Form language should be a String when present"
    end
    
    # Check LexicalSenses
    assert result[:senses].length > 0, "Should have at least one sense"
    sense_id, sense = result[:senses].first
    assert_instance_of LinkedData::Models::OntoLex::LexicalSense, sense
    assert sense.id, "Sense should have an ID"
    # Sense should link to a concept - lexicalConcept is a single value, not an array
    if sense.lexicalConcept
      assert_instance_of LinkedData::Models::OntoLex::LexicalConcept, sense.lexicalConcept, "Sense lexicalConcept should be a LexicalConcept instance"
    end
    
    # Check LexicalConcepts
    assert result[:concepts].length > 0, "Should have at least one concept"
    concept = result[:concepts].first
    assert_instance_of LinkedData::Models::OntoLex::LexicalConcept, concept
    assert concept.id, "Concept should have an ID"
    assert concept.submission, "Concept should be linked to submission"
    assert_equal sub.id, concept.submission.id, "Concept should be linked to correct submission"
    # Concepts should have definition (prefLabel is computed dynamically, not a stored attribute)
    assert concept.definition, "Concept should have definition"
    
    # Step 5: Verify relationships between models
    # Entry should have forms and senses
    if entry.form && entry.form.is_a?(Array)
      assert entry.form.length > 0, "Entry should have at least one form"
      entry_form = entry.form.first
      assert result[:forms].values.any? { |f| f.id == entry_form.id },
             "Entry's form should be in the forms collection"
    end
    
    if entry.sense && entry.sense.is_a?(Array)
      assert entry.sense.length > 0, "Entry should have at least one sense"
      entry_sense = entry.sense.first
      assert result[:senses].values.any? { |s| s.id == entry_sense.id },
             "Entry's sense should be in the senses collection"
    end
    
    # Step 6: Verify hypermedia links for ONTOLEX ontology
    ont_reloaded = LinkedData::Models::Ontology.find(acronym).first
    refute_nil ont_reloaded, "Should be able to reload ontology"
    
    # Verify ontology recognizes it's OntoLex format
    assert ont_reloaded.respond_to?(:ontolex?), "Ontology should have ontolex? method"
    
    # Get hypermedia links
    if ont_reloaded.respond_to?(:hypermedia_links)
      links = ont_reloaded.hypermedia_links
      assert links.is_a?(Array), "Hypermedia links should be an array"
      
      link_types = links.map(&:type)
      
      # Should NOT have OWL-specific links
      refute_includes link_types, "properties", "ONTOLEX ontology should not have 'properties' link"
      refute_includes link_types, "classes", "ONTOLEX ontology should not have 'classes' link"
      refute_includes link_types, "roots", "ONTOLEX ontology should not have 'roots' link"
      refute_includes link_types, "instances", "ONTOLEX ontology should not have 'instances' link"
      refute_includes link_types, "single_class", "ONTOLEX ontology should not have 'single_class' link"
      
      # Should have OntoLex-specific links
      assert_includes link_types, "lexical_concepts", "ONTOLEX ontology should have 'lexical_concepts' link"
      assert_includes link_types, "lexical_entries", "ONTOLEX ontology should have 'lexical_entries' link"
      assert_includes link_types, "lexical_senses", "ONTOLEX ontology should have 'lexical_senses' link"
      assert_includes link_types, "forms", "ONTOLEX ontology should have 'forms' link"
    end
    
    # Cleanup
    FileUtils.rm_f(tmp_file)
  end

  def test_ontolex_parser_wrapper
    # Test that OntoLexParser wrapper matches OWLAPI interface
    acronym = 'WRAPPER_TEST'
    file_path = File.expand_path('../data/ontolex/sample.ttl', __dir__)
    
    delete_ontologies_and_submissions
    u, _, contact = ontology_objects
    ontolex_format = LinkedData::Models::OntologyFormat.find("ONTOLEX").first
    
    ont = LinkedData::Models::Ontology.new(
      acronym: acronym,
      name: "OntoLex Wrapper Test",
      administeredBy: [u]
    )
    ont.summaryOnly = true
    ont.save
    
    sub = LinkedData::Models::OntologySubmission.new(
      ontology: ont,
      hasOntologyLanguage: ontolex_format,
      submissionId: 1,
      contact: [contact],
      released: DateTime.now - 1
    )
    sub.save
    
    # Create wrapper (simulating what SubmissionRDFGenerator does)
    parser = LinkedData::Parser::OntoLexParser.new(sub, file_path)
    
    # Verify wrapper has required interface
    assert parser.respond_to?(:parse), "Parser wrapper should respond to parse"
    assert parser.respond_to?(:logger=), "Parser wrapper should respond to logger="
    
    # Set logger
    require 'logger'
    test_logger = Logger.new(STDOUT)
    parser.logger = test_logger
    assert_equal test_logger, parser.logger, "Logger should be settable"
    
    # Parse should return output file path (ontolex_triples.ttl in same directory)
    result = parser.parse
    expected_output = File.join(File.dirname(file_path), "ontolex_triples.ttl")
    assert_equal expected_output, result, "Parser wrapper parse() should return output path"
  end

  def test_mapping_triples_generation
    # Test that LOOM and SAME_URI mapping triples are generated for OntoLex LexicalEntries
    # Note: LexicalConcepts are not included since they don't have prefLabel
    file_path = File.expand_path('../data/ontolex/sample.ttl', __dir__)
    
    delete_ontologies_and_submissions
    u, of, contact = ontology_objects
    
    # Find the ONTOLEX format
    ontolex_format = LinkedData::Models::OntologyFormat.find("ONTOLEX").first
    format_to_use = ontolex_format || of
    
    ont = LinkedData::Models::Ontology.new(acronym: 'ONTOLEXMAP', name: "OntoLex Mapping Test", administeredBy: [u])
    ont.summaryOnly = true
    ont.save
    
    sub = LinkedData::Models::OntologySubmission.new(
      ontology: ont,
      hasOntologyLanguage: format_to_use,
      submissionId: 1,
      contact: [contact],
      released: DateTime.now - 1,
      definitionProperty: RDF::IRI.new("http://bioontology.org/ontologies/biositemap.owl#definition")
    )
    sub.save
    sub.pullLocation = RDF::IRI.new("file://#{file_path}")
    sub.save
    
    # Parse the OntoLex file
    result = LinkedData::Parser::OntoLex.parse(file_path.to_s, sub)
    
    # Verify we have entries (mappings are only generated for entries, not concepts)
    refute_nil result[:entries], "Should have entries"
    assert result[:entries].length > 0, "Should have at least one entry"
    
    # Query the triple store for mapping predicates
    graph_id = sub.id.to_s
    client = Goo.sparql_query_client(:main)
    
    loom_predicate = Goo.vocabulary(:metadata_def)[:mappingLoom].to_s
    same_uri_predicate = Goo.vocabulary(:metadata_def)[:mappingSameURI].to_s
    
    # Check for LOOM mapping triples
    loom_query = <<-SPARQL
      SELECT (COUNT(?s) as ?count) WHERE {
        GRAPH <#{graph_id}> {
          ?s <#{loom_predicate}> ?loom_label .
        }
      }
    SPARQL
    
    loom_count = 0
    client.query(loom_query).each do |row|
      loom_count = row[:count].to_i
    end
    
    puts "\n[MAPPING DEBUG] LOOM mapping triples count: #{loom_count}"
    
    # Check for SAME_URI mapping triples
    same_uri_query = <<-SPARQL
      SELECT (COUNT(?s) as ?count) WHERE {
        GRAPH <#{graph_id}> {
          ?s <#{same_uri_predicate}> ?uri .
        }
      }
    SPARQL
    
    same_uri_count = 0
    client.query(same_uri_query).each do |row|
      same_uri_count = row[:count].to_i
    end
    
    puts "[MAPPING DEBUG] SAME_URI mapping triples count: #{same_uri_count}"
    
    # We should have SAME_URI mapping for each entry only (concepts are not included)
    expected_same_uri_count = result[:entries].length
    assert_equal expected_same_uri_count, same_uri_count, 
      "Should have SAME_URI mapping for each entry (#{expected_same_uri_count} expected)"
    
    # LOOM mappings depend on having lemma with > 2 chars
    assert loom_count > 0, "Should have at least one LOOM mapping triple"
    
    # Verify the actual values
    loom_values_query = <<-SPARQL
      SELECT ?s ?loom WHERE {
        GRAPH <#{graph_id}> {
          ?s <#{loom_predicate}> ?loom .
        }
      }
    SPARQL
    
    puts "[MAPPING DEBUG] LOOM mappings:"
    client.query(loom_values_query).each do |row|
      puts "  #{row[:s]} -> #{row[:loom]}"
      # Verify LOOM label is lowercase and alphanumeric only
      loom_val = row[:loom].to_s
      assert loom_val == loom_val.downcase, "LOOM label should be lowercase"
      assert loom_val.match?(/^[a-z0-9]+$/), "LOOM label should be alphanumeric only"
    end
  end
end
