# frozen_string_literal: true

require 'nokogiri'
require 'time'
require_relative 'relation_types'
require_relative 'inline_markup'

module EacCpf2
  # Serializes an ArchivesSpace agent as an EAC-CPF 2.0 document.
  #
  # Works on plain hashes so that it can be tested without ArchivesSpace. The
  # caller (EacCpf2::Exporter inside ArchivesSpace) is responsible for applying
  # EacCpf2::Publication first; this class serializes whatever it is given.
  class Serializer
    NAMESPACE = 'https://archivists.org/ns/eac/v2'
    SCHEMA_LOCATION = 'https://raw.githubusercontent.com/SAA-SDT/eac-cpf-schema/master/xml-schemas/eac-cpf/eac.xsd'
    # Extension attributes for data EAC-CPF has no element for. EAC-CPF 2.0
    # permits attributes from other namespaces on every element.
    EXTENSION_NAMESPACE = 'https://github.com/UIUCLibrary/aspace-eac-cpf-2#'
    XSI = 'http://www.w3.org/2001/XMLSchema-instance'

    ENTITY_TYPES = {
      'agent_person' => 'person',
      'agent_corporate_entity' => 'corporateBody',
      'agent_family' => 'family'
    }.freeze

    URI_SEGMENTS = {
      'agent_person' => 'people',
      'agent_corporate_entity' => 'corporate_entities',
      'agent_family' => 'families'
    }.freeze

    # name field => part/@localType, in the order ArchivesSpace's own exporter uses
    NAME_PARTS = {
      'agent_person' => {
        'primary_name' => 'surname', 'title' => 'title', 'prefix' => 'prefix', 'rest_of_name' => 'forename',
        'suffix' => 'suffix', 'fuller_form' => 'fuller_form', 'number' => 'numeration',
        'qualifier' => 'qualifier', 'dates' => 'dates'
      },
      'agent_family' => {
        'prefix' => 'prefix', 'family_name' => 'surname', 'number' => 'numeration', 'qualifier' => 'qualifier',
        'location' => 'location', 'dates' => 'dates', 'family_type' => 'family_type'
      },
      'agent_corporate_entity' => {
        'primary_name' => 'primary_name', 'subordinate_name_1' => 'subordinate_name_1',
        'subordinate_name_2' => 'subordinate_name_2', 'number' => 'numeration', 'qualifier' => 'qualifier',
        'location' => 'location', 'dates' => 'dates'
      }
    }.freeze

    MAINTENANCE_STATUS = {
      'new' => 'new', 'upgraded' => 'revised', 'revised_corrected' => 'revised', 'derived' => 'derived',
      'deleted' => 'deleted', 'cancelled_obsolete' => 'cancelled', 'deleted_split' => 'deletedSplit',
      'deleted_replaced' => 'deletedReplaced', 'deleted_merged' => 'deletedMerged'
    }.freeze

    PUBLICATION_STATUS = { 'approved' => 'approved', 'in_process' => 'inProcess' }.freeze

    MAINTENANCE_EVENT_TYPES = %w[cancelled created deleted derived revised unknown updated].freeze

    NARRATIVE_NOTES = {
      'note_bioghist' => 'biogHist',
      'note_general_context' => 'generalContext',
      'note_structure_or_genealogy' => 'structureOrGenealogy'
    }.freeze

    TERM_NOTES = {
      'note_mandate' => %w[mandates mandate],
      'note_legal_status' => %w[legalStatuses legalStatus]
    }.freeze

    TARGET_TYPES = {
      'resource' => 'resource', 'archival_object' => 'resource',
      'digital_object' => 'resource', 'digital_object_component' => 'resource'
    }.freeze

    # @param agent [Hash] filtered agent JSON (related_agents and subjects resolved)
    # @param records [Array<Hash>] published records the agent is linked to. Keys:
    #   'uri', 'title', 'jsonmodel_type', 'role', 'relator', and optionally
    #   'ead_id' and 'ref_id'
    # @param agency_name [String] fallback maintenance agency name
    # @param agency_code [String, nil] fallback maintenance agency code
    # @param base_url [String, nil] prefix for ArchivesSpace URIs in @valueURI
    # @param label [#call] (enumeration, value) -> display label
    def initialize(agent:, records: [], agency_name: 'ArchivesSpace', agency_code: nil, base_url: nil,
                   label: ->(_enum, value) { RelationTypes.humanize(value) })
      @agent = agent
      @records = records
      @agency_name = agency_name
      @agency_code = agency_code
      @base_url = base_url.to_s.sub(%r{/+\z}, '')
      @label = label
    end

    def to_xml
      Nokogiri::XML::Builder.new(encoding: 'UTF-8') { |xml| root(xml) }.to_xml
    end

    private

    attr_reader :agent

    def root(xml)
      xml.eac('xmlns' => NAMESPACE, 'xmlns:xsi' => XSI, 'xmlns:aspace' => EXTENSION_NAMESPACE,
              'xsi:schemaLocation' => "#{NAMESPACE} #{SCHEMA_LOCATION}") do
        control(xml)
        cpf_description(xml)
      end
    end

    # ---- control ---------------------------------------------------------

    def control(xml)
      record_control = Array(agent['agent_record_controls']).first || {}
      attrs = { 'maintenanceStatus' => maintenance_status(record_control) }
      publication = PUBLICATION_STATUS[record_control['publication_status']]
      attrs['publicationStatus'] = publication if publication

      xml.control(attrs) do
        xml.recordId record_id
        maintenance_agency(xml, record_control)
        maintenance_history(xml)
        sources(xml)
        convention_declarations(xml)
        language_declaration(xml, record_control)
        other_record_ids(xml)
        rights_declarations(xml)
      end
    end

    def maintenance_status(record_control)
      MAINTENANCE_STATUS[record_control['maintenance_status']] ||
        (agent['create_time'] && agent['create_time'] == agent['system_mtime'] ? 'new' : 'revised')
    end

    def record_id
      primary = Array(agent['agent_record_identifiers']).find { |id| id['primary_identifier'] && present?(id['record_identifier']) }
      primary ? primary['record_identifier'] : agent['uri']
    end

    def maintenance_agency(xml, record_control)
      code = present(record_control['maintenance_agency']) || present(@agency_code)
      name = present(record_control['agency_name']) || @agency_name

      xml.maintenanceAgency do
        xml.agencyCode code if code
        xml.agencyName name
        Array(agent['agent_other_agency_codes']).each do |other|
          next unless present?(other['maintenance_agency'])

          attrs = {}
          attrs['localType'] = other['agency_code_type'] if present?(other['agency_code_type'])
          xml.otherAgencyCode(other['maintenance_agency'], attrs)
        end
        descriptive_note(xml, record_control['maintenance_agency_note'])
      end
    end

    # ArchivesSpace rarely has maintenance history recorded, but EAC-CPF
    # requires at least one event, so creation and last modification are
    # synthesized from the record's timestamps when there is none. Usernames
    # are deliberately not exported.
    def maintenance_history(xml)
      events = Array(agent['agent_maintenance_histories']).select { |mh| present?(mh['event_date']) }
      xml.maintenanceHistory do
        if events.any?
          events.each do |mh|
            maintenance_event(xml, mh['maintenance_event_type'], mh['maintenance_agent_type'] || 'human',
                              present(mh['agent']) || 'unknown', mh['event_date'], mh['descriptive_note'])
          end
        else
          created = agent['create_time']
          modified = agent['user_mtime'] || agent['system_mtime']
          maintenance_event(xml, 'created', 'machine', 'ArchivesSpace', created || modified, nil)
          if created && modified && timestamp(modified) != timestamp(created)
            maintenance_event(xml, 'updated', 'machine', 'ArchivesSpace', modified, nil)
          end
        end
      end
    end

    def maintenance_event(xml, type, agent_type, agent_name, date, description)
      type = MAINTENANCE_EVENT_TYPES.include?(type) ? type : 'unknown'
      agent_type = %w[human machine].include?(agent_type) ? agent_type : 'human'
      xml.maintenanceEvent('maintenanceEventType' => type) do
        xml.agent(agent_name, 'agentType' => agent_type)
        stamp = timestamp(date)
        if stamp
          xml.eventDateTime(stamp, 'standardDateTime' => stamp)
        else
          xml.eventDateTime 'unknown'
        end
        xml.eventDescription description if present?(description)
      end
    end

    def sources(xml)
      sources = Array(agent['agent_sources']).select { |s| present?(s['source_entry']) || present?(s['file_uri']) }
      return if sources.empty?

      xml.sources do
        sources.each do |source|
          xml.source(link_attrs(source)) do
            xml.reference(present(source['source_entry']) || source['file_uri'])
            descriptive_note(xml, source['descriptive_note'])
          end
        end
      end
    end

    def convention_declarations(xml)
      Array(agent['agent_conventions_declarations']).each do |cd|
        reference = present(cd['citation']) || (cd['name_rule'] && @label.call('name_rule', cd['name_rule']))
        next unless present?(reference)

        xml.conventionDeclaration do
          xml.reference(reference, link_attrs(cd))
          xml.shortCode cd['name_rule'] if present?(cd['name_rule'])
          descriptive_note(xml, cd['descriptive_note'])
        end
      end
    end

    def language_declaration(xml, record_control)
      return unless present?(record_control['language'])

      xml.languageDeclaration('languageCode' => record_control['language']) do
        descriptive_note(xml, record_control['language_note'])
      end
    end

    def other_record_ids(xml)
      xml.otherRecordId(agent['uri'], 'localType' => 'archivesspace_uri') if agent['uri']
      Array(agent['agent_record_identifiers']).each do |id|
        next if id['primary_identifier'] || !present?(id['record_identifier'])

        attrs = {}
        attrs['localType'] = id['identifier_type'] || id['source'] if id['identifier_type'] || id['source']
        xml.otherRecordId(id['record_identifier'], attrs)
      end
    end

    def rights_declarations(xml)
      Array(agent['metadata_rights_declarations']).each do |mrd|
        reference = (mrd['license'] && @label.call('metadata_license', mrd['license'])) || mrd['file_uri']
        next unless present?(reference)

        xml.rightsDeclaration do
          attrs = {}
          attrs['href'] = mrd['file_uri'] if present?(mrd['file_uri'])
          xml.reference(reference, attrs)
          xml.shortCode mrd['license'] if present?(mrd['license'])
          descriptive_note(xml, mrd['descriptive_note'])
        end
      end
    end

    # ---- cpfDescription --------------------------------------------------

    def cpf_description(xml)
      xml.cpfDescription do
        identity(xml)
        description(xml)
        relations(xml)
        alternative_set(xml)
      end
    end

    def identity(xml)
      xml.identity do
        xml.entityType('value' => ENTITY_TYPES.fetch(agent['jsonmodel_type']))
        Array(agent['names']).each { |name| name_entry_or_set(xml, name) }
        Array(agent['agent_identifiers']).each do |id|
          next unless present?(id['entity_identifier'])

          attrs = {}
          attrs['localType'] = id['identifier_type'] if present?(id['identifier_type'])
          xml.identityId(id['entity_identifier'], attrs)
        end
      end
    end

    def name_entry_or_set(xml, name)
      parallel = Array(name['parallel_names'])
      if parallel.empty?
        name_entry(xml, name, with_dates: true)
      else
        xml.nameEntrySet do
          name_entry(xml, name, with_dates: false)
          parallel.each { |pname| name_entry(xml, pname.merge('authorized' => name['authorized']), with_dates: false) }
          use_dates(xml, name['use_dates'])
        end
      end
    end

    def name_entry(xml, name, with_dates:)
      attrs = { 'status' => name['authorized'] ? 'authorized' : 'alternative' }
      attrs['preferredForm'] = 'true' if name['is_display_name']
      attrs['languageOfElement'] = name['language'] if present?(name['language'])
      attrs['scriptOfElement'] = name['script'] if present?(name['script'])
      attrs['vocabularySource'] = name['source'] if present?(name['source'])
      attrs['valueURI'] = name['authority_id'] if uri?(name['authority_id'])
      attrs['aspace:sortName'] = name['sort_name'] if present?(name['sort_name'])
      attrs['aspace:authorityId'] = name['authority_id'] if present?(name['authority_id']) && !uri?(name['authority_id'])

      parts = NAME_PARTS.fetch(agent['jsonmodel_type']).filter_map do |field, local_type|
        [local_type, name[field]] if present?(name[field])
      end
      parts = [[nil, name['sort_name']]] if parts.empty? && present?(name['sort_name'])
      return if parts.empty?

      xml.nameEntry(attrs) do
        parts.each { |local_type, value| xml.part(value, local_type ? { 'localType' => local_type } : {}) }
        use_dates(xml, name['use_dates']) if with_dates
      end
    end

    def use_dates(xml, dates)
      dates = Array(dates).select { |date| date_content?(date) }
      return if dates.empty?

      xml.useDates { dates_element(xml, dates) }
    end

    def description(xml)
      places = agent_places
      occupations = term_subrecords('agent_occupations')
      functions = term_subrecords('agent_functions')
      topics = term_subrecords('agent_topics')
      genders = Array(agent['agent_genders']).select { |g| present?(g['gender']) }
      languages = Array(agent['used_languages']).select { |l| present?(l['language']) || present?(l['script']) }
      notes = Array(agent['notes'])
      exist_dates = Array(agent['dates_of_existence']).select { |date| date_content?(date) }

      return if [places, occupations, functions, topics, genders, languages, notes, exist_dates].all?(&:empty?)

      xml.description do
        if genders.any?
          xml.demographicDescriptions do
            genders.each do |gender|
              xml.demographicDescription('localType' => 'gender') do
                xml.term @label.call('gender', gender['gender'])
                dates_element(xml, gender['dates'])
                descriptive_note(xml, note_texts(gender['notes']))
              end
            end
          end
        end
        term_group(xml, 'functions', 'function', functions)
        languages_used(xml, languages)
        term_notes(xml, notes, 'note_legal_status')
        if topics.any?
          xml.localDescriptions do
            term_group_items(xml, 'localDescription', topics, 'localType' => 'associatedSubject')
          end
        end
        term_notes(xml, notes, 'note_mandate')
        term_group(xml, 'occupations', 'occupation', occupations)
        places_element(xml, places)
        exist_dates.each do |date|
          xml.existDates { dates_element(xml, [date]) }
        end
        notes.each { |note| narrative_note(xml, note) }
      end
    end

    def term_subrecords(key)
      Array(agent[key]).select { |sub| subject_terms(sub).any? }
    end

    def subject_terms(sub)
      Array(sub['subjects']).filter_map { |ref| first_term(ref['_resolved']) }
    end

    def first_term(subject)
      return nil unless subject

      present(subject['title']) || present(Array(subject['terms']).map { |t| t['term'] }.compact.join(' -- '))
    end

    def term_group(xml, group, element, subs)
      return if subs.empty?

      xml.send(group) { term_group_items(xml, element, subs, {}) }
    end

    def term_group_items(xml, element, subs, attrs)
      subs.each do |sub|
        xml.send(element, attrs) do
          subject_terms(sub).each { |term| xml.term term }
          dates_element(xml, sub['dates'])
          Array(sub['places']).filter_map { |ref| first_term(ref['_resolved']) }.each { |place| xml.placeName place }
          descriptive_note(xml, note_texts(sub['notes']))
        end
      end
    end

    def languages_used(xml, languages)
      return if languages.empty?

      xml.languagesUsed do
        languages.each do |lang|
          xml.languageUsed do
            if present?(lang['language'])
              xml.language(@label.call('language_iso639_2', lang['language']), 'languageCode' => lang['language'])
            end
            if present?(lang['script'])
              xml.writingSystem(@label.call('script_iso15924', lang['script']), 'scriptCode' => lang['script'])
            end
            descriptive_note(xml, note_texts(lang['notes']))
          end
        end
      end
    end

    def agent_places
      Array(agent['agent_places']).select { |place| subject_terms(place).any? }
    end

    def places_element(xml, places)
      return if places.empty?

      xml.places do
        places.each do |place|
          xml.place do
            subject_terms(place).each { |term| xml.placeName term }
            xml.placeRole @label.call('place_role', place['place_role']) if present?(place['place_role'])
            dates_element(xml, place['dates'])
            descriptive_note(xml, note_texts(place['notes']))
          end
        end
      end
    end

    def term_notes(xml, notes, type)
      notes = notes.select { |note| note['jsonmodel_type'] == type }
      return if notes.empty?

      group, element = TERM_NOTES.fetch(type)
      xml.send(group) do
        notes.each do |note|
          xml.send(element) do
            xml.term(present(note['label']) || @label.call('note_type', type.sub(/\Anote_/, '')))
            paragraphs = subnote_paragraphs(note)
            if paragraphs.any?
              xml.descriptiveNote { paragraphs.each { |para| xml.p { InlineMarkup.write(xml, para) } } }
            end
          end
        end
      end
    end

    # biogHist, generalContext and structureOrGenealogy: head, abstract, then
    # paragraphs, lists and chronologies in the order they were entered.
    def narrative_note(xml, note)
      element = NARRATIVE_NOTES[note['jsonmodel_type']]
      return unless element

      subnotes = Array(note['subnotes'])
      abstracts = subnotes.select { |sub| sub['jsonmodel_type'] == 'note_abstract' }
      body = subnotes - abstracts
      return if abstracts.empty? && body.none? { |sub| subnote_content?(sub) }

      xml.send(element) do
        xml.head note['label'] if present?(note['label'])
        if element == 'biogHist'
          abstracts.each do |sub|
            text = Array(sub['content']).join(' ')
            xml.abstract { InlineMarkup.write(xml, InlineMarkup.paragraphs(text).flatten) } if present?(text)
          end
        else
          body = abstracts + body
        end
        body.each { |sub| subnote(xml, sub, allow_chronology: element == 'biogHist') }
      end
    end

    def subnote_content?(sub)
      case sub['jsonmodel_type']
      when 'note_text', 'note_citation', 'note_abstract' then present?(Array(sub['content']).join)
      else Array(sub['items'] || sub['levels']).any?
      end
    end

    def subnote(xml, sub, allow_chronology:)
      case sub['jsonmodel_type']
      when 'note_text', 'note_abstract'
        paragraphs(xml, sub['content'])
      when 'note_citation'
        citation(xml, sub)
      when 'note_orderedlist'
        list(xml, sub['title'], Array(sub['items']), 'listType' => 'ordered', 'style' => numeration(sub['enumeration']))
      when 'note_definedlist'
        defined_list(xml, sub)
      when 'note_outline'
        Array(sub['levels']).each { |level| outline_level(xml, level) }
      when 'note_chronology'
        allow_chronology ? chronology(xml, sub) : chronology_as_list(xml, sub)
      end
    end

    def paragraphs(xml, content)
      InlineMarkup.paragraphs(content).each { |para| xml.p { InlineMarkup.write(xml, para) } }
    end

    def citation(xml, sub)
      href = sub.dig('xlink', 'href')
      text = Array(sub['content']).join(' ')
      return paragraphs(xml, text) unless present?(href)

      xml.p do
        xml.reference('href' => href) { xml.text(present(text) || href) }
      end
    end

    NUMERATIONS = {
      'arabic' => 'decimal', 'loweralpha' => 'lower-alpha', 'upperalpha' => 'upper-alpha',
      'lowerroman' => 'lower-roman', 'upperroman' => 'upper-roman'
    }.freeze

    # EAC-CPF 2.0 has no @numeration; @style takes CSS.
    def numeration(enumeration)
      NUMERATIONS[enumeration] && "list-style-type: #{NUMERATIONS[enumeration]}"
    end

    def list(xml, title, items, attrs)
      items = items.reject { |item| item.to_s.strip.empty? }
      return if items.empty?

      xml.list(attrs.compact) do
        xml.head title if present?(title)
        items.each { |item| xml.item { InlineMarkup.write(xml, InlineMarkup.paragraphs(item).flatten) } }
      end
    end

    def defined_list(xml, sub)
      items = Array(sub['items']).select { |item| present?(item['label']) || present?(item['value']) }
      return if items.empty?

      xml.list('listType' => 'unordered', 'localType' => 'defined') do
        xml.head sub['title'] if present?(sub['title'])
        items.each do |item|
          xml.item do
            if present?(item['label'])
              xml.span(item['label'], 'localType' => 'label')
              xml.text(': ')
            end
            InlineMarkup.write(xml, InlineMarkup.paragraphs(item['value'].to_s).flatten)
          end
        end
      end
    end

    def outline_level(xml, level)
      items = Array(level['items'])
      return if items.empty?

      xml.list('listType' => 'unordered', 'localType' => 'outline') do
        items.each do |item|
          if item.is_a?(Hash)
            outline_level(xml, item)
          elsif present?(item)
            xml.item { InlineMarkup.write(xml, InlineMarkup.paragraphs(item).flatten) }
          end
        end
      end
    end

    def chronology(xml, sub)
      entries = chronology_entries(sub)
      return if entries.empty?

      attrs = {}
      attrs['localType'] = sub['title'] if present?(sub['title'])
      xml.chronList(attrs) do
        entries.each do |date, event|
          xml.chronItem do
            if present?(date)
              xml.date(date)
            else
              xml.date('status' => 'unknown')
            end
            xml.event { InlineMarkup.write(xml, InlineMarkup.paragraphs(event).flatten) }
          end
        end
      end
    end

    def chronology_as_list(xml, sub)
      items = chronology_entries(sub).map { |date, event| present?(date) ? "#{date}: #{event}" : event }
      list(xml, sub['title'], items, 'listType' => 'unordered', 'localType' => 'chronology')
    end

    def chronology_entries(sub)
      Array(sub['items']).flat_map do |item|
        Array(item['events']).reject { |event| event.to_s.strip.empty? }.map { |event| [item['event_date'], event] }
      end
    end

    def subnote_paragraphs(note)
      Array(note['subnotes']).flat_map do |sub|
        case sub['jsonmodel_type']
        when 'note_text', 'note_abstract', 'note_citation' then InlineMarkup.paragraphs(sub['content'])
        else []
        end
      end
    end

    # ---- relations -------------------------------------------------------

    def relations(xml)
      agent_relations = Array(agent['related_agents']).select { |rel| rel['_resolved'] }
      resources = Array(agent['agent_resources']).select { |res| present?(res['linked_resource']) }
      return if agent_relations.empty? && @records.empty? && resources.empty?

      xml.relations do
        agent_relations.each { |rel| agent_relation(xml, rel) }
        @records.each { |record| record_relation(xml, record) }
        resources.each { |res| external_resource_relation(xml, res) }
      end
    end

    def agent_relation(xml, rel)
      target = rel['_resolved']
      both_persons = agent['jsonmodel_type'] == 'agent_person' && target['jsonmodel_type'] == 'agent_person'
      term = RelationTypes.for_agent_relator(rel['relator'], both_persons: both_persons)
      name = display_name(target)

      xml.relation do
        target_attrs = { 'targetType' => ENTITY_TYPES.fetch(target['jsonmodel_type'], 'agent') }
        target_attrs['valueURI'] = absolute(target['uri']) if target['uri']
        xml.targetEntity(target_attrs) { xml.part name }
        dates_element(xml, [rel['dates']].compact)
        relation_type(xml, term, rel['relator'])
        if present?(rel['specific_relator'])
          xml.relationType(@label.call('agent_relationship_specific_relator', rel['specific_relator']),
                           'localType' => 'specific_relator')
        end
        xml.relationType(rel['relationship_uri'], 'valueURI' => rel['relationship_uri']) if uri?(rel['relationship_uri'])
        descriptive_note(xml, rel['description'])
      end
    end

    def record_relation(xml, record)
      term = RelationTypes.for_record_role(record['role'])
      xml.relation do
        attrs = { 'targetType' => TARGET_TYPES.fetch(record['jsonmodel_type'], 'resource') }
        attrs['valueURI'] = absolute(record['uri']) if record['uri']
        attrs['aspace:recordType'] = record['jsonmodel_type'] if record['jsonmodel_type']
        attrs['aspace:eadId'] = record['ead_id'] if present?(record['ead_id'])
        attrs['aspace:refId'] = record['ref_id'] if present?(record['ref_id'])
        attrs['aspace:resourceUri'] = record['resource_uri'] if present?(record['resource_uri'])
        xml.targetEntity(attrs) { xml.part(present(record['title']) || record['uri']) }
        relation_type(xml, term, record['role'])
        if present?(record['relator'])
          xml.relationType(@label.call('linked_agent_archival_record_relators', record['relator']),
                           'localType' => 'relator', 'vocabularySource' => 'marcrelator',
                           'valueURI' => "http://id.loc.gov/vocabulary/relators/#{record['relator']}")
        end
      end
    end

    def external_resource_relation(xml, res)
      xml.relation do
        attrs = { 'targetType' => 'resource' }
        attrs['valueURI'] = res['file_uri'] if uri?(res['file_uri'])
        xml.targetEntity(attrs) { xml.part res['linked_resource'] }
        dates_element(xml, Array(res['dates']).first(1))
        Array(res['places']).filter_map { |ref| first_term(ref['_resolved']) }.each do |place|
          xml.place { xml.placeName place }
        end
        relation_type(xml, RelationTypes.for_record_role(res['linked_agent_role']), res['linked_agent_role'])
        descriptive_note(xml, res['linked_resource_description'])
      end
    end

    def relation_type(xml, term, local_type)
      attrs = { 'localType' => local_type }
      if term.value_uri
        attrs['vocabularySource'] = RelationTypes::RICO_VOCABULARY
        attrs['vocabularySourceURI'] = RelationTypes::RICO_NAMESPACE
        attrs['valueURI'] = term.value_uri
      end
      xml.relationType(term.label, attrs)
    end

    def alternative_set(xml)
      sets = Array(agent['agent_alternate_sets']).select { |s| present?(s['set_component']) || present?(s['descriptive_note']) }
      return if sets.empty?

      xml.alternativeSet do
        sets.each do |set|
          xml.setComponent(link_attrs(set)) do
            xml.componentEntry set['set_component'] if present?(set['set_component'])
            descriptive_note(xml, set['descriptive_note'])
          end
        end
      end
    end

    # ---- dates -----------------------------------------------------------

    def date_content?(date)
      return false unless date.is_a?(Hash)

      if date['date_type_structured'] == 'range'
        range = date['structured_date_range'] || {}
        %w[begin_date_expression begin_date_standardized end_date_expression end_date_standardized].any? { |k| present?(range[k]) }
      else
        single = date['structured_date_single'] || {}
        present?(single['date_expression']) || present?(single['date_standardized'])
      end
    end

    # Writes one date as <date>/<dateRange>, or several as <dateSet>.
    def dates_element(xml, dates)
      dates = Array(dates).select { |date| date_content?(date) }
      return if dates.empty?

      if dates.length == 1
        single_date(xml, dates.first)
      else
        xml.dateSet { dates.each { |date| single_date(xml, date) } }
      end
    end

    def single_date(xml, date)
      attrs = {}
      attrs['localType'] = date['date_label'] if present?(date['date_label'])
      attrs['aspace:certainty'] = date['date_certainty'] if present?(date['date_certainty'])

      if date['date_type_structured'] == 'range'
        range = date['structured_date_range']
        xml.dateRange(attrs) do
          date_point(xml, :fromDate, range['begin_date_expression'], range['begin_date_standardized'],
                     range['begin_date_standardized_type'])
          date_point(xml, :toDate, range['end_date_expression'], range['end_date_standardized'],
                     range['end_date_standardized_type'])
        end
      else
        single = date['structured_date_single']
        date_point(xml, :date, single['date_expression'], single['date_standardized'],
                   single['date_standardized_type'], attrs)
      end
    end

    STANDARDIZED_ATTRIBUTES = { 'standard' => 'standardDate', 'not_before' => 'notBefore', 'not_after' => 'notAfter' }.freeze

    def date_point(xml, element, expression, standardized, standardized_type, attrs = {})
      return unless present?(expression) || present?(standardized)

      attrs = attrs.dup
      attrs[STANDARDIZED_ATTRIBUTES.fetch(standardized_type || 'standard', 'standardDate')] = standardized if present?(standardized)
      xml.send(element, present(expression) || standardized, attrs)
    end

    # ---- helpers ---------------------------------------------------------

    def display_name(agent_json)
      present(agent_json.dig('display_name', 'sort_name')) || present(agent_json['title']) || agent_json['uri']
    end

    def note_texts(notes)
      Array(notes).filter_map do |note|
        next if note['jsonmodel_type'] == 'note_citation'

        present(Array(note['content']).join("\n\n"))
      end.join("\n\n")
    end

    def descriptive_note(xml, text)
      paragraphs = InlineMarkup.paragraphs(text.to_s)
      return if paragraphs.empty?

      xml.descriptiveNote { paragraphs.each { |para| xml.p { InlineMarkup.write(xml, para) } } }
    end

    def link_attrs(record)
      attrs = {}
      attrs['href'] = record['file_uri'] if uri?(record['file_uri'])
      attrs['linkRole'] = record['xlink_role_attribute'] if uri?(record['xlink_role_attribute'])
      attrs['linkTitle'] = record['xlink_title_attribute'] if present?(record['xlink_title_attribute'])
      attrs
    end

    def absolute(uri)
      @base_url.empty? ? uri : "#{@base_url}#{uri}"
    end

    def timestamp(value)
      return nil unless present?(value)

      Time.parse(value.to_s).utc.iso8601
    rescue ArgumentError
      nil
    end

    def uri?(value)
      present?(value) && value.to_s.match?(%r{\A[a-z][a-z0-9+.-]*://\S+\z}i)
    end

    def present?(value)
      !value.nil? && !value.to_s.strip.empty?
    end

    def present(value)
      present?(value) ? value.to_s : nil
    end
  end
end
