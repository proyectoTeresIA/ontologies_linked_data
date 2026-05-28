require 'benchmark'
require 'tmpdir'

module LinkedData
module Mappings
  OUTSTANDING_LIMIT = 30

    def self.mapping_predicates
      predicates = {}
      predicates["CUI"] = ["http://bioportal.bioontology.org/ontologies/umls/cui"]
      predicates["SAME_URI"] =
        [Goo.vocabulary(:metadata_def)[:mappingSameURI].to_s]
      predicates["LOOM"] =
        [Goo.vocabulary(:metadata_def)[:mappingLoom].to_s]
      predicates["REST"] =
        [Goo.vocabulary(:metadata_def)[:mappingRest].to_s]
      return predicates
    end

    def self.internal_mapping_predicates
      predicates = {}
      predicates["SKOS:EXACT_MATCH"] = ["http://www.w3.org/2004/02/skos/core#exactMatch"]
      predicates["SKOS:CLOSE_MATCH"] = ["http://www.w3.org/2004/02/skos/core#closeMatch"]
      predicates["SKOS:BROAD_MATCH"] = ["http://www.w3.org/2004/02/skos/core#broadMatch"]
      predicates["SKOS:NARROW_MATCH"] = ["http://www.w3.org/2004/02/skos/core#narrowMatch"]
      predicates["SKOS:RELATED_MATCH"] = ["http://www.w3.org/2004/02/skos/core#relatedMatch"]
      predicates["SKOS:RELATED"] = ["http://www.w3.org/2004/02/skos/core#related"]
      return predicates
    end

    # The three SKOS predicates used for cross-ontology term linking in OntoLex ontologies
    SKOS_TERM_MAPPING_PREDICATES = {
      'closeMatch' => 'http://www.w3.org/2004/02/skos/core#closeMatch',
      'exactMatch' => 'http://www.w3.org/2004/02/skos/core#exactMatch',
      'related'    => 'http://www.w3.org/2004/02/skos/core#related'
    }.freeze

    def self.handle_triple_store_downtime(logger = nil)
      epr = Goo.sparql_query_client(:main)
      status = epr.status

    if status[:exception]
      logger.info(status[:exception]) if logger
      exit(1)
    end

    if status[:outstanding] > OUTSTANDING_LIMIT
      logger.info("The triple store number of outstanding queries exceeded #{OUTSTANDING_LIMIT}. Exiting...") if logger
      exit(1)
    end
  end

  def self.mapping_counts(enable_debug=false, logger=nil, reload_cache=false, arr_acronyms=[])
    logger = nil unless enable_debug
    t = Time.now
    latest = self.retrieve_latest_submissions(options={ acronyms:arr_acronyms })
    counts = {}
    i = 0
    epr = Goo.sparql_query_client(:main)

    latest.each do |acro, sub|
      self.handle_triple_store_downtime(logger) if LinkedData.settings.goo_backend_name === '4store'
      t0 = Time.now
      s_counts = self.mapping_ontologies_count(sub, nil, reload_cache=reload_cache)
      s_total = 0

      s_counts.each do |k,v|
        s_total += v
      end

      # For OntoLex ontologies, also count SKOS cross-ontology mappings
      if is_ontolex_ontology?(acro)
        ontolex_count = self.ontolex_mapping_count_for_submission(sub)
        s_total += ontolex_count
      end

      counts[acro] = s_total
      i += 1

      if enable_debug
        logger.info("#{i}/#{latest.count} " +
            "Retrieved #{s_total} records for #{acro} in #{Time.now - t0} seconds.")
        logger.flush
      end
      sleep(5)
    end

    if enable_debug
      logger.info("Total time #{Time.now - t} sec.")
      logger.flush
    end
    return counts
  end

  def self.mapping_ontologies_count(sub1, sub2, reload_cache=false)
    template = <<-eos
{
  GRAPH <#{sub1.id.to_s}> {
      ?s1 <predicate> ?o .
  }
  GRAPH graph {
      ?s2 <predicate> ?o .
  }
}
eos
    group_count = sub2.nil? ? {} : nil
    count = 0
    latest_sub_ids = self.retrieve_latest_submission_ids
    epr = Goo.sparql_query_client(:main)

    acr1 = sub1.id.to_s.split("/")[-3]
    acr2 = sub2.nil? ? nil : sub2.id.to_s.split("/")[-3]
    skip_loom_same_uri = is_ontolex_ontology?(acr1) || (!acr2.nil? && is_ontolex_ontology?(acr2))

    mapping_predicates().each do |_source, mapping_predicate|
      next if skip_loom_same_uri && ["LOOM", "SAME_URI"].include?(_source)
      block = template.gsub("predicate", mapping_predicate[0])
      query_template = <<-eos
      SELECT variables
      WHERE {
      block
      filter
      } group
      eos
      query = query_template.sub("block", block)
      filter = _source == "SAME_URI" ? '' : 'FILTER (?s1 != ?s2)'

      if sub2.nil?
        ont_id = sub1.id.to_s.split("/")[0..-3].join("/")
        #STRSTARTS is used to not count older graphs
        filter += "\nFILTER (!STRSTARTS(str(?g),'#{ont_id}'))"
        query = query.sub("graph","?g")
        query = query.sub("filter",filter)
        query = query.sub("variables","?g (count(?s1) as ?c)")
        query = query.sub("group","GROUP BY ?g")
      else
        query = query.sub("graph","<#{sub2.id.to_s}>")
        query = query.sub("filter",filter)
        query = query.sub("variables","(count(?s1) as ?c)")
        query = query.sub("group","")
      end
      graphs = [sub1.id, LinkedData::Models::MappingProcess.type_uri]
      graphs << sub2.id unless sub2.nil?

      if sub2.nil?
        # When searching for mappings to ANY other ontology, we need access to ALL
        # latest submission graphs, not just sub1's graph.
        latest_sub_ids.each_value do |sub_uri|
          graphs << RDF::URI.new(sub_uri) unless sub_uri == sub1.id.to_s
        end
        solutions = epr.query(query, graphs: graphs, reload_cache: reload_cache)

        solutions.each do |sol|
          acr = sol[:g].to_s.split("/")[-3]
          next unless latest_sub_ids[acr] == sol[:g].to_s

          if group_count[acr].nil?
            group_count[acr] = 0
          end
          group_count[acr] += sol[:c].object
        end
      else
        solutions = epr.query(query,
                              graphs: graphs )
        solutions.each do |sol|
          count += sol[:c].object
        end
      end
    end #per predicate query

    # Directional SKOS predicates: count ?s1 in sub1 with a SKOS link to a subject in another graph
    skos_template = <<-eos
{
  GRAPH <#{sub1.id.to_s}> {
    ?s1 <predicate> ?o .
  }
  GRAPH graph {
    ?o ?skos_p ?skos_v .
  }
}
eos

    internal_mapping_predicates.each do |_skos_source, skos_predicate|
      block = skos_template.gsub("predicate", skos_predicate[0])
      query_template = <<-eos
      SELECT variables
      WHERE {
      block
      filter
      } group
      eos
      query = query_template.sub("block", block)
      filter = 'FILTER (?s1 != ?o)'

      if sub2.nil?
        ont_id = sub1.id.to_s.split("/")[0..-3].join("/")
        filter += "\nFILTER (!STRSTARTS(str(?g),'#{ont_id}'))"
        query = query.sub("graph", "?g")
        query = query.sub("filter", filter)
        query = query.sub("variables", "?g (count(DISTINCT ?s1) as ?c)")
        query = query.sub("group", "GROUP BY ?g")
      else
        query = query.sub("graph", "<#{sub2.id.to_s}>")
        query = query.sub("filter", filter)
        query = query.sub("variables", "(count(DISTINCT ?s1) as ?c)")
        query = query.sub("group", "")
      end
      graphs = [sub1.id, LinkedData::Models::MappingProcess.type_uri]
      graphs << sub2.id unless sub2.nil?

      if sub2.nil?
        latest_sub_ids.each_value do |sub_uri|
          graphs << RDF::URI.new(sub_uri) unless sub_uri == sub1.id.to_s
        end
        solutions = epr.query(query, graphs: graphs, reload_cache: reload_cache)

        solutions.each do |sol|
          acr = sol[:g].to_s.split("/")[-3]
          next unless latest_sub_ids[acr] == sol[:g].to_s

          if group_count[acr].nil?
            group_count[acr] = 0
          end
          group_count[acr] += sol[:c].object
        end
      else
        solutions = epr.query(query, graphs: graphs)
        solutions.each do |sol|
          count += sol[:c].object
        end
      end
    end #per SKOS predicate

    if sub2.nil?
      return group_count
    end
    return count
  end

  def self.empty_page(page,size)
      p = Goo::Base::Page.new(page,size,nil,[])
      p.aggregate = 0
      return p
  end

    def self.mappings_ontologies(sub1, sub2, page, size, classId = nil, reload_cache = false)
      sub1, acr1 = extract_acronym(sub1)
      sub2, acr2 = extract_acronym(sub2)

      mappings = []
      persistent_count = 0

      if classId.nil?
        persistent_count = count_mappings(acr1, acr2)
        return LinkedData::Mappings.empty_page(page, size) if persistent_count == 0
      end

      query = mappings_ont_build_query(classId, page, size, sub1, sub2)
      epr = Goo.sparql_query_client(:main)
      graphs = [sub1]
      unless sub2.nil?
        graphs << sub2
      end
      solutions = epr.query(query, graphs: graphs, reload_cache: reload_cache)
      s1 = nil
      s1 = RDF::URI.new(classId.to_s) unless classId.nil?

      solutions.each do |sol|
        graph2 = sub2.nil? ? sol[:g] : sub2
        s1 = sol[:s1] if classId.nil?
        backup_mapping = nil

        if sol[:source].to_s == "REST"
          backup_mapping = LinkedData::Models::RestBackupMapping
                             .find(sol[:o]).include(:process, :class_urns).first
          backup_mapping.process.bring_remaining
        end

        classes = get_mapping_classes_instance(s1, sub1, sol[:s2], graph2)

        mapping = if backup_mapping.nil?
                    LinkedData::Models::Mapping.new(classes, sol[:source].to_s)
                  else
                    LinkedData::Models::Mapping.new(
                      classes, sol[:source].to_s,
                      backup_mapping.process, backup_mapping.id)
                  end

        mappings << mapping
      end

      if size == 0
        return mappings
      end

      page = Goo::Base::Page.new(page, size, persistent_count, mappings)
      return page
    end

  def self.mappings_ontology(sub,page,size,classId=nil,reload_cache=false)
    return self.mappings_ontologies(sub,nil,page,size,classId=classId,
                                    reload_cache=reload_cache)
  end

  # Check if an ontology uses OntoLex format based on the submission's hasOntologyLanguage
  def self.is_ontolex_ontology?(acronym)
    return @ontolex_cache[acronym] if defined?(@ontolex_cache) && @ontolex_cache.key?(acronym)
    
    @ontolex_cache ||= {}
    
    begin
      ont = LinkedData::Models::Ontology.find(acronym).first
      return false unless ont
      
      sub = ont.latest_submission(status: :any)
      return false unless sub
      
      sub.bring(:hasOntologyLanguage) if sub.bring?(:hasOntologyLanguage)
      is_ontolex = sub.hasOntologyLanguage && sub.hasOntologyLanguage.id.to_s.include?('ONTOLEX')
      @ontolex_cache[acronym] = is_ontolex
      return is_ontolex
    rescue => e
      @ontolex_cache[acronym] = false
      return false
    end
  end

  def self.read_only_class(classId,submissionId)
      ontologyId = submissionId
      acronym = nil
      unless submissionId["submissions"].nil?
        ontologyId = submissionId.split("/")[0..-3]
        acronym = ontologyId.last
        ontologyId = ontologyId.join("/")
      else
        acronym = ontologyId.split("/")[-1]
      end
      ontology = LinkedData::Models::Ontology
            .read_only(
              id: RDF::IRI.new(ontologyId),
              acronym: acronym)
      submission = LinkedData::Models::OntologySubmission
            .read_only(
              id: RDF::IRI.new(ontologyId+"/submissions/latest"),
              # id: RDF::IRI.new(submissionId),
              ontology: ontology)
      
      # Check if this is an OntoLex ontology and return appropriate type
      if is_ontolex_ontology?(acronym)
        mappedClass = LinkedData::Models::OntoLex::LexicalEntry
              .read_only(
                id: RDF::IRI.new(classId),
                submission: submission)
      else
        mappedClass = LinkedData::Models::Class
              .read_only(
                id: RDF::IRI.new(classId),
                submission: submission,
                urn_id: LinkedData::Models::Class.urn_id(acronym,classId) )
      end
      return mappedClass
  end

  def self.migrate_rest_mappings(acronym)
    mappings = LinkedData::Models::RestBackupMapping
                .where.include(:uuid, :class_urns, :process).all
    if mappings.length == 0
      return []
    end
    triples = []

    rest_predicate = mapping_predicates()["REST"][0]
    mappings.each do |m|
      m.class_urns.each do |u|
        u = u.to_s
        if u.start_with?("urn:#{acronym}")
          class_id = u.split(":")[2..-1].join(":")
          triples <<
            " <#{class_id}> <#{rest_predicate}> <#{m.id}> . "
        end
      end
    end
    return triples
  end

  def self.delete_rest_mapping(mapping_id)
    mapping = get_rest_mapping(mapping_id)
    if mapping.nil?
      return nil
    end
    rest_predicate = mapping_predicates()["REST"][0]
    classes = mapping.classes
    classes.each do |c|
      sub = c.submission
      unless sub.id.to_s["latest"].nil?
        #the submission in the class might point to latest
        sub = LinkedData::Models::Ontology.find(c.submission.ontology.id)
                .first
                .latest_submission
      end
      graph_delete = RDF::Graph.new
      graph_delete << [c.id, RDF::URI.new(rest_predicate), mapping.id]
      Goo.sparql_update_client.delete_data(graph_delete, graph: sub.id)
    end
    mapping.process.delete
    backup = LinkedData::Models::RestBackupMapping.find(mapping_id).first
    unless backup.nil?
      backup.delete
    end
    return mapping
  end

  def self.get_rest_mapping(mapping_id)
    backup = LinkedData::Models::RestBackupMapping.find(mapping_id).first
    if backup.nil?
      return nil
    end
    rest_predicate = mapping_predicates()["REST"][0]
    qmappings = <<-eos
SELECT DISTINCT ?s1 ?c1 ?s2 ?c2 ?uuid ?o
WHERE {
  ?uuid <http://data.bioontology.org/metadata/process> ?o .

  GRAPH ?s1 {
    ?c1 <#{rest_predicate}> ?uuid .
  }
  GRAPH ?s2 {
    ?c2 <#{rest_predicate}> ?uuid .
  }
FILTER(?uuid = <#{LinkedData::Models::Base.replace_url_prefix_to_id(mapping_id)}>)
FILTER(?s1 != ?s2)
} LIMIT 1
      eos
      epr = Goo.sparql_query_client(:main)
      graphs = [LinkedData::Models::MappingProcess.type_uri]
      mapping = nil
      epr.query(qmappings,
                graphs: graphs).each do |sol|
        classes = [read_only_class(sol[:c1].to_s, sol[:s1].to_s),
                   read_only_class(sol[:c2].to_s, sol[:s2].to_s)]
        process = LinkedData::Models::MappingProcess.find(sol[:o]).first
        mapping = LinkedData::Models::Mapping.new(classes, 'REST',
                                                  process,
                                                  sol[:uuid])
    end
    return mapping
  end

  def self.create_rest_mapping(classes,process)
    unless process.instance_of? LinkedData::Models::MappingProcess
      raise ArgumentError, "Process should be instance of MappingProcess"
    end
    if classes.length != 2
      raise ArgumentError, "Create REST is avalaible for two classes. " +
                           "Request contains #{classes.length} classes."
    end
    #first create back up mapping that lives across submissions
    backup_mapping = LinkedData::Models::RestBackupMapping.new
    backup_mapping.uuid = UUID.new.generate
    backup_mapping.process = process
    class_urns = []
    classes.each do |c|
      if c.instance_of?LinkedData::Models::Class
        acronym = c.submission.id.to_s.split("/")[-3]
        class_urns << RDF::URI.new(
          LinkedData::Models::Class.urn_id(acronym,c.id.to_s))

      else
        class_urns << RDF::URI.new(c.urn_id())
      end
    end
    backup_mapping.class_urns = class_urns
    backup_mapping.save

    #second add the mapping id to current submission graphs
    rest_predicate = mapping_predicates()["REST"][0]
    classes.each do |c|
      sub = c.submission
      unless sub.id.to_s["latest"].nil?
        #the submission in the class might point to latest
        sub = LinkedData::Models::Ontology.find(c.submission.ontology.id).first.latest_submission
      end
      graph_insert = RDF::Graph.new
      graph_insert << [c.id, RDF::URI.new(rest_predicate), backup_mapping.id]
      Goo.sparql_update_client.insert_data(graph_insert, graph: sub.id)
    end
    mapping = LinkedData::Models::Mapping.new(classes,"REST", process, backup_mapping.id)
    return mapping
  end

  def self.mappings_for_classids(class_ids,sources=["REST","CUI"])
    class_ids = class_ids.uniq
    predicates = {}
    sources.each do |t|
      predicates[mapping_predicates()[t][0]] = t
    end
    qmappings = <<-eos
SELECT DISTINCT ?s1 ?c1 ?s2 ?c2 ?pred
WHERE {
  GRAPH ?s1 {
    ?c1 ?pred ?o .
  }
  GRAPH ?s2 {
    ?c2 ?pred ?o .
  }
FILTER(?s1 != ?s2)
FILTER(filter_pred)
FILTER(filter_classes)
}
eos
    qmappings = qmappings.gsub("filter_pred",
                    predicates.keys.map { |x| "?pred = <#{x}>"}.join(" || "))
    qmappings = qmappings.gsub("filter_classes",
                      class_ids.map { |x| "?c1 = <#{x}>" }.join(" || "))
    epr = Goo.sparql_query_client(:main)
    graphs = [LinkedData::Models::MappingProcess.type_uri]
    mappings = []
    epr.query(qmappings,
              graphs: graphs).each do |sol|
      classes = [ read_only_class(sol[:c1].to_s,sol[:s1].to_s),
                read_only_class(sol[:c2].to_s,sol[:s2].to_s) ]
      source = predicates[sol[:pred].to_s]
      mappings << LinkedData::Models::Mapping.new(classes,source)
    end
    return mappings
  end

  def self.recent_rest_mappings(n)
    graphs = [LinkedData::Models::MappingProcess.type_uri]
    qdate = <<-eos
SELECT DISTINCT ?s
FROM <#{LinkedData::Models::MappingProcess.type_uri}>
WHERE { ?s <http://data.bioontology.org/metadata/date> ?o }
ORDER BY DESC(?o) LIMIT #{n}
eos
    epr = Goo.sparql_query_client(:main)
    procs = []
    epr.query(qdate, graphs: graphs,query_options: {rules: :NONE}).each do |sol|
      procs << sol[:s]
    end
    if procs.length == 0
      return []
    end
    graphs = [LinkedData::Models::MappingProcess.type_uri]
    proc_object = Hash.new
    LinkedData::Models::MappingProcess.where
        .include(LinkedData::Models::MappingProcess.attributes)
        .all.each do |obj|
          #highly cached query
          proc_object[obj.id.to_s] = obj
    end
    procs = procs.map { |x| "?o = #{x.to_ntriples}" }.join " || "
    rest_predicate = mapping_predicates()["REST"][0]
    qmappings = <<-eos
SELECT DISTINCT ?ont1 ?c1 ?ont2 ?c2 ?o ?uuid
WHERE {
  ?uuid <http://data.bioontology.org/metadata/process> ?o .

  ?s1 <http://data.bioontology.org/metadata/ontology> ?ont1 .
  GRAPH ?s1 {
    ?c1 <#{rest_predicate}> ?uuid .
  }
  ?s2 <http://data.bioontology.org/metadata/ontology> ?ont2 .
  GRAPH ?s2 {
    ?c2 <#{rest_predicate}> ?uuid .
  }
FILTER(?ont1 != ?ont2)
FILTER(?c1 != ?c2)
FILTER (#{procs})
}
eos
    epr = Goo.sparql_query_client(:main)
    mappings = []
    epr.query(qmappings,
              graphs: graphs,query_options: {rules: :NONE}).each do |sol|
      classes = [ read_only_class(sol[:c1].to_s,sol[:ont1].to_s),
                read_only_class(sol[:c2].to_s,sol[:ont2].to_s) ]
      process = proc_object[sol[:o].to_s]
      mapping = LinkedData::Models::Mapping.new(classes,"REST",
                                                process,
                                                sol[:uuid])
      mappings << mapping
    end
    return mappings.sort_by { |x| x.process.date }.reverse[0..n-1]
  end

  def self.retrieve_latest_submission_ids(options = {})
    include_views = options[:include_views] || false
    metadata_ontology = Goo.vocabulary(:metadata)[:ontology].to_s
    metadata_submissionId = Goo.vocabulary(:metadata)[:submissionId].to_s
    metadata_submissionStatus = Goo.vocabulary(:metadata)[:submissionStatus].to_s
    metadata_code = Goo.vocabulary(:metadata)[:code].to_s
    metadata_viewOf = Goo.vocabulary(:metadata)[:viewOf].to_s
    
    ids_query = <<-eos
PREFIX xsd: <http://www.w3.org/2001/XMLSchema#>
SELECT (CONCAT(xsd:string(?ontology), "/submissions/", xsd:string(MAX(?submissionId))) as ?id)
WHERE { 
	?id <#{metadata_ontology}> ?ontology .
	?id <#{metadata_submissionId}> ?submissionId .
	?id <#{metadata_submissionStatus}> ?submissionStatus .
	?submissionStatus <#{metadata_code}> "RDF" . 
	include_views_filter 
}
GROUP BY ?ontology
    eos
    include_views_filter = include_views ? '' : <<-eos
	OPTIONAL { 
		?id <#{metadata_ontology}> ?ontJoin .  
	} 
	OPTIONAL { 
		?ontJoin <#{metadata_viewOf}> ?viewOf .  
	} 
	FILTER(!BOUND(?viewOf))
    eos
    ids_query.gsub!("include_views_filter", include_views_filter)
    epr = Goo.sparql_query_client(:main)
    solutions = epr.query(ids_query)
    latest_ids = {}

    solutions.each do |sol|
      acr = sol[:id].to_s.split("/")[-3]
      latest_ids[acr] = sol[:id].object
    end

    latest_ids
  end

  def self.retrieve_latest_submissions(options = {})
    acronyms = (options[:acronyms] || [])
    status = (options[:status] || "RDF").to_s.upcase
    include_ready = status.eql?("READY") ? true : false
    status = "RDF" if status.eql?("READY")
    any = status.eql?("ANY")
    include_views = options[:include_views] || false

    if any
      submissions_query = LinkedData::Models::OntologySubmission.where
    else
      submissions_query = LinkedData::Models::OntologySubmission.where(submissionStatus: [code: status])
    end
    submissions_query = submissions_query.filter(Goo::Filter.new(ontology: [:viewOf]).unbound) unless include_views
    submissions = submissions_query.include(:submissionStatus,:submissionId, ontology: [:acronym]).to_a
    submissions.select! { |sub| acronyms.include?(sub.ontology.acronym) } unless acronyms.empty?
    latest_submissions = {}

    submissions.each do |sub|
      next if include_ready && !sub.ready?
      latest_submissions[sub.ontology.acronym] ||= sub
      latest_submissions[sub.ontology.acronym] = sub if sub.submissionId > latest_submissions[sub.ontology.acronym].submissionId
    end
    return latest_submissions
  end

  def self.create_mapping_counts(logger, arr_acronyms=[])
    ont_msg = arr_acronyms.empty? ? "all ontologies" : "ontologies [#{arr_acronyms.join(', ')}]"

    time = Benchmark.realtime do
      self.create_mapping_count_totals_for_ontologies(logger, arr_acronyms)
    end
    logger.info("Completed rebuilding total mapping counts for #{ont_msg} in #{(time/60).round(1)} minutes.")

    time = Benchmark.realtime do
      self.create_mapping_count_pairs_for_ontologies(logger, arr_acronyms)
    end
    logger.info("Completed rebuilding mapping count pairs for #{ont_msg} in #{(time/60).round(1)} minutes.")
  end

  def self.create_mapping_count_totals_for_ontologies(logger, arr_acronyms)
    new_counts = self.mapping_counts(enable_debug=true, logger=logger, reload_cache=true, arr_acronyms)
    persistent_counts = {}
    f = Goo::Filter.new(:pair_count) == false
    LinkedData::Models::MappingCount.where.filter(f)
      .include(:ontologies, :count)
    .include(:all)
    .all
    .each do |m|
      persistent_counts[m.ontologies.first] = m
    end

    num_counts = new_counts.keys.length
    ctr = 0

    new_counts.each_key do |acr|
      new_count = new_counts[acr]
      ctr += 1

      if persistent_counts.include?(acr)
        inst = persistent_counts[acr]

        if new_count != inst.count
          inst.bring_remaining
          inst.count = new_count

          begin
            if inst.valid?
              inst.save(override_security: true)
            else
              logger.error("Error updating mapping count for #{acr}: #{inst.id.to_s}. #{inst.errors}")
              next
            end
          rescue Exception => e
            logger.error("Exception updating mapping count for #{acr}: #{inst.id.to_s}. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
            next
          end
        end
      else
        m = LinkedData::Models::MappingCount.new
        m.ontologies = [acr]
        m.pair_count = false
        m.count = new_count

        begin
          if m.valid?
            m.save(override_security: true)
          else
            logger.error("Error saving new mapping count for #{acr}. #{m.errors}")
            next
          end
        rescue Exception => e
          logger.error("Exception saving new mapping count for #{acr}. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
          next
        end
      end
      remaining = num_counts - ctr
      logger.info("Total mapping count saved for #{acr}: #{new_count}. " << ((remaining > 0) ? "#{remaining} counts remaining..." : "All done!"))
    end
  end

  # This generates pair mapping counts for the given
  # ontologies to ALL other ontologies in the system
  def self.create_mapping_count_pairs_for_ontologies(logger, arr_acronyms)
    latest_submissions = self.retrieve_latest_submissions(options={acronyms:arr_acronyms})
    ont_total = latest_submissions.length
    logger.info("There is a total of #{ont_total} ontologies to process...")
    ont_ctr = 0
    # filename = 'mapping_pairs.ttl'
    # temp_dir = Dir.tmpdir
    # temp_file_path = File.join(temp_dir, filename)
    # temp_dir = '/Users/mdorf/Downloads/test/'
    # temp_file_path = File.join(File.dirname(file_path), "test.ttl")
    # fsave = File.open(temp_file_path, "a")

    latest_submissions.each do |acr, sub|
      self.handle_triple_store_downtime(logger) if LinkedData.settings.goo_backend_name === '4store'
      new_counts = nil
      time = Benchmark.realtime do
        new_counts = self.mapping_ontologies_count(sub, nil, reload_cache=true)
      end
      logger.info("Retrieved new mapping pair counts for #{acr} in #{time} seconds.")
      ont_ctr += 1
      persistent_counts = {}
      LinkedData::Models::MappingCount.where(pair_count: true).and(ontologies: acr)
                                      .include(:ontologies, :count).all.each do |m|
        other = m.ontologies.first

        if other == acr
          other = m.ontologies[1]
        end
        persistent_counts[other] = m
      end

      num_counts = new_counts.keys.length
      logger.info("Ontology: #{acr}. #{num_counts} mapping pair counts to record...")
      logger.info("------------------------------------------------")
      ctr = 0

      new_counts.each_key do |other|
        new_count = new_counts[other]
        ctr += 1

        if persistent_counts.include?(other)
          inst = persistent_counts[other]

          if new_count != inst.count
            inst.bring_remaining
            inst.pair_count = true
            inst.count = new_count

            begin
              if inst.valid?
                inst.save(override_security: true)
                # inst.save({ batch: fsave })
              else
                logger.error("Error updating mapping count for the pair [#{acr}, #{other}]: #{inst.id.to_s}. #{inst.errors}")
                next
              end
            rescue Exception => e
              logger.error("Exception updating mapping count for the pair [#{acr}, #{other}]: #{inst.id.to_s}. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
              next
            end
          end
        else
          m = LinkedData::Models::MappingCount.new
          m.count = new_count
          m.ontologies = [acr,other]
          m.pair_count = true

          begin
            if m.valid?
              m.save(override_security: true)
              # m.save({ batch: fsave })
            else
              logger.error("Error saving new mapping count for the pair [#{acr}, #{other}]. #{m.errors}")
              next
            end
          rescue Exception => e
            logger.error("Exception saving new mapping count for the pair [#{acr}, #{other}]. #{e.class}: #{e.message}\n#{e.backtrace.join("\n")}")
            next
          end
        end
        remaining = num_counts - ctr
        logger.info("Mapping count saved for the pair [#{acr}, #{other}]: #{new_count}. " << ((remaining > 0) ? "#{remaining} counts remaining for #{acr}..." : "All done!"))
        wait_interval = 250

        if ctr % wait_interval == 0
          sec_to_wait = 1
          logger.info("Waiting #{sec_to_wait} second" << ((sec_to_wait > 1) ? 's' : '') << '...')
          sleep(sec_to_wait)
        end
      end
      remaining_ont = ont_total - ont_ctr
      logger.info("Completed processing pair mapping counts for #{acr}. " << ((remaining_ont > 0) ? "#{remaining_ont} ontologies remaining..." : "All ontologies processed!"))
      sleep(5)
    end
    # fsave.close
  end

    def self.ontolex_mappings_for_concept(submission, concept_id, page, size)
      epr   = Goo.sparql_query_client(:main)
      graph = submission.id.to_s

      source_acr     = graph.split("/")[-3]
      source_ont_uri = graph.split("/submissions/").first
      source_ont_ro  = LinkedData::Models::Ontology.read_only(
        id: RDF::IRI.new(source_ont_uri), acronym: source_acr
      )
      source_sub_ro  = LinkedData::Models::OntologySubmission.read_only(
        id: RDF::IRI.new(graph), ontology: source_ont_ro
      )
      latest = retrieve_latest_submission_ids

      # subject is the LexicalConcept — entries are found via isEvokedBy (on the concept)
      concept_subject = concept_id ? "<#{concept_id}>" : "?concept"

      pred_to_label = {}
      pred_in_list  = internal_mapping_predicates.map do |label, pred|
        uri = Array(pred).first
        pred_to_label[uri] = label
        "<#{uri}>"
      end.join(", ")

      lc_type          = "http://www.w3.org/ns/lemon/ontolex#LexicalConcept"
      evokes_uri       = "http://www.w3.org/ns/lemon/ontolex#evokes"
      is_evoked_by_uri = "http://www.w3.org/ns/lemon/ontolex#isEvokedBy"
      pref_label       = "http://www.w3.org/2004/02/skos/core#prefLabel"

      # Forward query: concept→isEvokedBy→sourceEntry, concept→SKOS→target, target→isEvokedBy→targetEntry.
      # Using isEvokedBy on the concept side captures all entries even if the entry
      # itself does not declare the forward `ontolex:evokes` triple.
      # Multiple source entries per concept produce multiple rows (one per pair).
      fwd_query = <<-SPARQL
SELECT DISTINCT ?sourceEntry ?concept ?target ?pred ?prefLabel ?targetGraph ?targetEntry ?targetIsEntry
WHERE {
  GRAPH <#{graph}> { #{concept_subject} <#{is_evoked_by_uri}> ?sourceEntry . }
  GRAPH <#{graph}> { #{concept_subject} ?pred ?target . }
  FILTER(?pred IN (#{pred_in_list}))
  MINUS { GRAPH <#{graph}> { ?target a <#{lc_type}> . } }
  OPTIONAL {
    GRAPH ?targetGraph { ?target <#{is_evoked_by_uri}> ?targetEntry . }
    FILTER(?targetGraph != <#{graph}>)
  }
  OPTIONAL {
    GRAPH ?targetGraph { ?target a <#{lc_type}> . }
    FILTER(?targetGraph != <#{graph}>)
  }
  OPTIONAL {
    GRAPH ?targetGraphB { ?target <#{evokes_uri}> ?targetIsEntry . }
    FILTER(?targetGraphB != <#{graph}>)
  }
  OPTIONAL { GRAPH ?anyGraph { ?target <#{pref_label}> ?prefLabel . } }
}
      SPARQL

      # Reverse query: concepts in OTHER graphs map TO our concepts.
      # concept→isEvokedBy→conceptEntry ensures we only show concepts that have entries.
      rev_query = <<-SPARQL
SELECT DISTINCT ?conceptEntry ?concept ?source ?pred ?sourceGraph ?sourceEntry ?sourceIsEntry ?srcLabel
WHERE {
  GRAPH <#{graph}> { #{concept_subject} <#{is_evoked_by_uri}> ?conceptEntry . }
  GRAPH ?sourceGraph { ?source ?pred #{concept_subject} . }
  FILTER(?pred IN (#{pred_in_list}))
  FILTER(?sourceGraph != <#{graph}>)
  OPTIONAL { GRAPH ?sourceGraph { ?source <#{is_evoked_by_uri}> ?sourceEntry . } }
  OPTIONAL { GRAPH ?sourceGroupB { ?source <#{evokes_uri}> ?sourceIsEntry . } }
  OPTIONAL { GRAPH ?anyGraph { ?source <#{pref_label}> ?srcLabel . } }
}
      SPARQL

      seen     = {}
      mappings = []

      # Process forward results
      epr.query(fwd_query).each do |sol|
        source_cid  = concept_id || sol[:concept]&.to_s || ''
        src_entry   = sol[:sourceEntry]&.to_s
        target_uri  = sol[:target].to_s

        # sourceEntry is always bound (required clause) — use it directly
        src_display = src_entry.present? ? src_entry : source_cid
        next if src_display.empty?

        # Resolve target display to its entry URI; skip if target has no entry
        tgt_entry    = sol[:targetEntry]&.to_s
        tgt_is_entry = sol[:targetIsEntry]&.to_s
        if tgt_entry.present?
          tgt_display = tgt_entry
        elsif tgt_is_entry.present?
          tgt_display = target_uri  # target IS already an entry (has ontolex:evokes)
        else
          next  # target is a concept with no lexical entries — skip
        end

        pair_key = "fwd:#{src_display}|#{tgt_display}"
        next if seen[pair_key]
        seen[pair_key] = true

        target_graph = sol[:targetGraph]&.to_s
        unless target_graph
          latest.each_value do |sub_uri|
            next if sub_uri == graph
            cand_acr = sub_uri.split("/")[-3]
            target_graph = sub_uri if target_uri.include?(cand_acr)
          end
        end
        target_acr = target_graph ? target_graph.split("/")[-3] : nil
        next unless target_acr

        source_obj  = LinkedData::Models::OntoLex::LexicalConcept.read_only(
          id: RDF::URI.new(src_display), submission: source_sub_ro
        )
        target_ont  = LinkedData::Models::Ontology.read_only(
          id: RDF::IRI.new(target_graph.split("/submissions/").first), acronym: target_acr
        )
        target_sub  = LinkedData::Models::OntologySubmission.read_only(
          id: RDF::IRI.new(target_graph), ontology: target_ont
        )
        target_obj  = LinkedData::Models::OntoLex::LexicalConcept.read_only(
          id: RDF::URI.new(tgt_display), submission: target_sub,
          prefLabel: sol[:prefLabel]&.to_s
        )

        rel = pred_to_label[sol[:pred].to_s] || sol[:pred].to_s.split('#').last
        mappings << LinkedData::Models::Mapping.new([source_obj, target_obj], rel)
      end

      # Process reverse results (this graph's concepts are targeted by other graphs)
      epr.query(rev_query).each do |sol|
        our_cid         = concept_id || sol[:concept]&.to_s || ''
        our_entry       = sol[:conceptEntry]&.to_s
        other_uri       = sol[:source].to_s
        src_graph_uri   = sol[:sourceGraph]&.to_s
        other_acr       = src_graph_uri ? src_graph_uri.split("/")[-3] : nil
        next unless other_acr

        # Our side: conceptEntry is always bound (required clause)
        src_display = our_entry.present? ? our_entry : our_cid
        next if src_display.empty?

        # Other side: resolve to entry or skip
        other_entry    = sol[:sourceEntry]&.to_s
        other_is_entry = sol[:sourceIsEntry]&.to_s
        if other_entry.present?
          tgt_display = other_entry
        elsif other_is_entry.present?
          tgt_display = other_uri
        else
          next  # other concept has no entry — skip
        end

        pair_key = "rev:#{src_display}|#{tgt_display}"
        next if seen[pair_key]
        seen[pair_key] = true

        source_obj = LinkedData::Models::OntoLex::LexicalConcept.read_only(
          id: RDF::URI.new(src_display), submission: source_sub_ro
        )
        other_ont  = LinkedData::Models::Ontology.read_only(
          id: RDF::IRI.new(src_graph_uri.split("/submissions/").first), acronym: other_acr
        )
        other_sub  = LinkedData::Models::OntologySubmission.read_only(
          id: RDF::IRI.new(src_graph_uri), ontology: other_ont
        )
        target_obj = LinkedData::Models::OntoLex::LexicalConcept.read_only(
          id: RDF::URI.new(tgt_display), submission: other_sub,
          prefLabel: sol[:srcLabel]&.to_s
        )

        rel = pred_to_label[sol[:pred].to_s] || sol[:pred].to_s.split('#').last
        mappings << LinkedData::Models::Mapping.new([source_obj, target_obj], rel)
      end

      total = mappings.size
      return empty_page(page, size) if total == 0

      if size > 0
        paged = mappings[(page - 1) * size, size] || []
        Goo::Base::Page.new(page, size, total, paged)
      else
        Goo::Base::Page.new(1, total, total, mappings)
      end
    end

    def self.ontolex_mapping_count_for_submission(submission)
      graph  = submission.id.to_s
      epr    = Goo.sparql_query_client(:main)

      pred_in_list = internal_mapping_predicates.values.map { |p| "<#{Array(p).first}>" }.join(", ")
      query = <<-SPARQL
SELECT (COUNT(DISTINCT ?target) AS ?c)
WHERE {
  GRAPH <#{graph}> { ?concept ?pred ?target . }
  FILTER(?pred IN (#{pred_in_list}))
  MINUS { GRAPH <#{graph}> { ?target a <http://www.w3.org/ns/lemon/ontolex#LexicalConcept> . } }
}
      SPARQL

      epr.query(query).map { |sol| sol[:c].object.to_i }.first || 0
    end

    # Given a concept URI and its submission, returns cross-ontology SKOS entries
    # linked via skos:closeMatch, skos:exactMatch, and skos:related.
    #
    # For each matching concept in another ontology, finds all lexical entries that
    # evoke that concept and collects their writtenRep values.
    #
    # Returns a hash:
    #   {
    #     'closeMatch' => [{ ontology_acronym: 'ONT', entry_id: 'http://...', written_reps: ['word'] }, ...],
    #     'exactMatch' => [...],
    #     'related'    => [...]
    #   }
    # Only relation types with at least one result are included.
    def self.ontolex_skos_cross_entries(submission, concept_id)
      return {} unless submission && concept_id && !concept_id.empty?

      epr    = Goo.sparql_query_client(:main)
      graph  = submission.id.to_s

      pred_in_list = SKOS_TERM_MAPPING_PREDICATES.values
                                                  .map { |uri| "<#{uri}>" }.join(", ")
      # Inverse map from URI to relation type key
      predicate_to_key = SKOS_TERM_MAPPING_PREDICATES.invert

      query = <<-SPARQL
SELECT DISTINCT ?predicate ?targetGraph ?targetEntry ?writtenRep ?language
WHERE {
  GRAPH <#{graph}> {
    <#{concept_id}> ?predicate ?targetConcept .
  }
  FILTER(?predicate IN (#{pred_in_list}))
  MINUS { GRAPH <#{graph}> { ?targetConcept a <http://www.w3.org/ns/lemon/ontolex#LexicalConcept> . } }
  GRAPH ?targetGraph {
    ?targetEntry <http://www.w3.org/ns/lemon/ontolex#evokes> ?targetConcept .
    OPTIONAL {
      ?targetEntry <http://purl.org/dc/terms/language> ?language .
    }
    OPTIONAL {
      ?targetEntry <http://www.w3.org/ns/lemon/ontolex#lexicalForm> ?targetForm .
      ?targetForm <http://www.w3.org/ns/lemon/ontolex#writtenRep> ?writtenRep .
    }
  }
  FILTER(?targetGraph != <#{graph}>)
}
      SPARQL

      # Accumulate: entry_id -> { rel_type, ontology_acronym, written_reps[] }
      entries_by_id = {}

      begin
        epr.query(query).each do |sol|
          pred_uri     = sol[:predicate].to_s
          target_graph = sol[:targetGraph].to_s
          target_entry = sol[:targetEntry].to_s
          written_rep  = sol[:writtenRep] ? sol[:writtenRep].object.to_s : nil

          rel_type = predicate_to_key[pred_uri] || pred_uri.split('#').last
          acr = target_graph.split("/")[-3]

          language = sol[:language] ? sol[:language].to_s.split('/').last : nil

          unless entries_by_id.key?(target_entry)
            entries_by_id[target_entry] = {
              rel_type:         rel_type,
              ontology_acronym: acr,
              entry_id:         target_entry,
              written_reps:     [],
              language:         language
            }
          end

          entries_by_id[target_entry][:language] ||= language if language

          if written_rep && !written_rep.empty?
            entries_by_id[target_entry][:written_reps] << written_rep
            entries_by_id[target_entry][:written_reps].uniq!
          end
        end
      rescue StandardError => e
        return {}
      end

      result = {}
      entries_by_id.each_value do |entry|
        rel = entry[:rel_type]
        next unless SKOS_TERM_MAPPING_PREDICATES.key?(rel)

        result[rel] ||= []
        result[rel] << {
          ontology_acronym: entry[:ontology_acronym],
          entry_id:         entry[:entry_id],
          written_reps:     entry[:written_reps],
          language:         entry[:language]
        }
      end

      result
    end

    private

    def self.get_mapping_classes_instance(s1, graph1, s2, graph2)
      [read_only_class(s1.to_s, graph1.to_s),
       read_only_class(s2.to_s, graph2.to_s)]
    end

    def self.mappings_ont_build_query(class_id, page, size, sub1, sub2)
      acr1 = sub1.to_s.split("/")[-3]
      acr2 = sub2.nil? ? nil : sub2.to_s.split("/")[-3]
      skip_loom_same_uri = is_ontolex_ontology?(acr1) || (!acr2.nil? && is_ontolex_ontology?(acr2))

      blocks = []
      mapping_predicates.each do |_source, mapping_predicate|
        next if skip_loom_same_uri && ["LOOM", "SAME_URI"].include?(_source)
        blocks << mappings_union_template(class_id, sub1, sub2,
                                          mapping_predicate[0],
                                          "BIND ('#{_source}' AS ?source)")
      end






      class_id_subject = class_id.nil? ? '?s1' : "<#{class_id.to_s}>"
      source_graph     = sub1.nil? ? '?g' : "<#{sub1.to_s}>"

      internal_mapping_predicates.each do |_source, predicate|
        if sub2.nil?
          blocks << <<-eos
        {
          GRAPH #{source_graph} {
            #{class_id_subject} <#{predicate[0]}> ?s2 .
          }
          BIND(<http://data.bioontology.org/metadata/ExternalMappings> AS ?g)
          BIND(?s2 AS ?o)
          BIND ('#{_source}' AS ?source)
        }
          eos
        else
          blocks << <<-eos
        {
          GRAPH #{source_graph} {
            #{class_id_subject} <#{predicate[0]}> ?s2 .
          }
          GRAPH <#{sub2.to_s}> {
            ?s2 ?skos_p_var ?skos_o_var .
          }
          BIND(?s2 AS ?o)
          BIND ('#{_source}' AS ?source)
        }
          eos
        end
      end

      filter = class_id.nil? ? "FILTER ((?s1 != ?s2) || (?source = 'SAME_URI'))" : ''
      if sub2.nil?
        ont_id = sub1.to_s.split("/")[0..-3].join("/")
        filter += "\nFILTER (!STRSTARTS(str(?g),'#{ont_id}')"
        filter += " || " + internal_mapping_predicates.keys.map{|x| "(?source = '#{x}')"}.join('||')
        filter += ")"
      end

      variables = "?s2 #{sub2.nil? ? '?g' : ''} ?source ?o"
      variables = "?s1 " + variables if class_id.nil?

      pagination = ''
      if size > 0
        limit = size
        offset = (page - 1) * size
        pagination = "OFFSET #{offset} LIMIT #{limit}"
      end

      query = <<-eos
SELECT DISTINCT #{variables}
WHERE {
   #{blocks.join("\nUNION\n")}
   #{filter}
} #{pagination}
      eos

      query
    end

    def self.mappings_union_template(class_id, sub1, sub2, predicate, bind)
      class_id_subject = class_id.nil? ? '?s1' : "<#{class_id.to_s}>"
      target_graph = sub2.nil? ? '?g' : "<#{sub2.to_s}>"
      union_template = <<-eos
{
  GRAPH <#{sub1.to_s}> {
      #{class_id_subject} <#{predicate}> ?o .
  }
  GRAPH #{target_graph} {
      ?s2 <#{predicate}> ?o .
  }
  #{bind}
}
      eos
    end

    def self.count_mappings(acr1, acr2)
      count = LinkedData::Models::MappingCount.where(ontologies: acr1)
      count = count.and(ontologies: acr2) unless acr2.nil?
      f = Goo::Filter.new(:pair_count) == (not acr2.nil?)
      count = count.filter(f)
      count = count.include(:count)
      pcount_arr = count.all
      pcount_arr.length == 0 ? 0 : pcount_arr.first.count
    end

    def self.extract_acronym(submission)
      sub = submission
      if submission.nil?
        acr = nil
      elsif submission.respond_to?(:id)
        # Case where sub2 is a Submission
        sub = submission.id
        acr = sub.to_s.split("/")[-3]
      else
        acr = sub.to_s
      end

      return sub, acr
    end

  end
end