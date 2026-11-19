# frozen_string_literal: true

# An agent exercising the parts of the ArchivesSpace agent model that the
# UIUC data does not use, so the serializer's output for them is validated
# against the schema too. Shaped like the JSON ArchivesSpace returns with
# related_agents, subjects and places resolved.
module RichAgent
  module_function

  def date(label, expression: nil, begin_std: nil, end_std: nil, single: nil)
    if single
      { 'date_label' => label, 'date_type_structured' => 'single',
        'structured_date_single' => { 'date_expression' => expression, 'date_standardized' => single,
                                      'date_standardized_type' => 'standard' } }
    else
      { 'date_label' => label, 'date_type_structured' => 'range', 'date_certainty' => 'approximate',
        'structured_date_range' => { 'begin_date_expression' => expression, 'begin_date_standardized' => begin_std,
                                     'begin_date_standardized_type' => 'not_before',
                                     'end_date_standardized' => end_std } }
    end
  end

  def subject(title, publish: true)
    { 'ref' => '/subjects/1', '_resolved' => { 'title' => title, 'publish' => publish, 'terms' => [{ 'term' => title }] } }
  end

  def related(relator, type, name, publish: true)
    segment = { 'agent_person' => 'people', 'agent_family' => 'families', 'agent_corporate_entity' => 'corporate_entities' }[type]
    { 'relator' => relator, 'ref' => "/agents/#{segment}/9",
      '_resolved' => { 'uri' => "/agents/#{segment}/9", 'jsonmodel_type' => type, 'publish' => publish,
                       'display_name' => { 'sort_name' => name } } }
  end

  def agent
    {
      'jsonmodel_type' => 'agent_person', 'uri' => '/agents/people/42', 'publish' => true,
      'create_time' => '2020-01-01T00:00:00Z', 'system_mtime' => '2024-05-01T12:00:00Z',
      'agent_contacts' => [{ 'name' => 'Private Contact', 'email' => 'secret@example.edu' }],
      'agent_record_identifiers' => [
        { 'primary_identifier' => true, 'record_identifier' => 'n79021164', 'source' => 'naf' },
        { 'primary_identifier' => false, 'record_identifier' => 'local-42', 'identifier_type' => 'local' }
      ],
      'agent_record_controls' => [{ 'maintenance_status' => 'revised_corrected', 'publication_status' => 'approved',
                                    'maintenance_agency' => 'IU-Ar', 'agency_name' => 'University of Illinois Archives',
                                    'language' => 'eng', 'language_note' => 'Described in English.' }],
      'agent_other_agency_codes' => [{ 'agency_code_type' => 'oclc', 'maintenance_agency' => 'UIU' }],
      'agent_maintenance_histories' => [{ 'maintenance_event_type' => 'created', 'maintenance_agent_type' => 'human',
                                          'agent' => 'Archivist', 'event_date' => '2019-03-04',
                                          'descriptive_note' => 'Migrated from Archon.' }],
      'agent_conventions_declarations' => [{ 'name_rule' => 'dacs', 'citation' => 'Describing Archives: A Content Standard',
                                             'file_uri' => 'https://saa-ts-dacs.github.io/' }],
      'agent_sources' => [{ 'source_entry' => 'Daily Illini, 1950', 'descriptive_note' => 'Obituary.' }],
      'metadata_rights_declarations' => [{ 'license' => 'cc0', 'file_uri' => 'https://creativecommons.org/publicdomain/zero/1.0/' }],
      'agent_identifiers' => [{ 'entity_identifier' => '0000-0001-2345-6789', 'identifier_type' => 'orcid' }],
      'names' => [
        { 'primary_name' => 'Smith', 'rest_of_name' => 'Jane', 'dates' => '1900-1980', 'authorized' => true,
          'is_display_name' => true, 'source' => 'naf', 'authority_id' => 'http://id.loc.gov/authorities/names/n79021164',
          'sort_name' => 'Smith, Jane, 1900-1980', 'use_dates' => [date('usage', expression: '1920-1980', begin_std: '1920', end_std: '1980')],
          'parallel_names' => [{ 'primary_name' => 'Смит', 'rest_of_name' => 'Джейн', 'language' => 'rus',
                                 'script' => 'Cyrl', 'sort_name' => 'Смит, Джейн' }] },
        { 'primary_name' => 'Doe', 'rest_of_name' => 'Jane', 'authorized' => false, 'sort_name' => 'Doe, Jane' }
      ],
      'dates_of_existence' => [date('existence', expression: '1900-1980', begin_std: '1900', end_std: '1980')],
      'agent_genders' => [{ 'gender' => 'woman', 'dates' => [] }],
      'used_languages' => [{ 'language' => 'eng', 'script' => 'Latn', 'notes' => [{ 'jsonmodel_type' => 'note_text', 'content' => 'Wrote in English.' }] }],
      'agent_places' => [{ 'publish' => true, 'place_role' => 'place_of_birth', 'subjects' => [subject('Urbana (Ill.)')],
                           'dates' => [date('existence', single: '1900')] },
                         { 'publish' => false, 'subjects' => [subject('Unpublished Place')] }],
      'agent_occupations' => [{ 'publish' => true, 'subjects' => [subject('Librarians'), subject('Hidden term', publish: false)],
                                'places' => [subject('Chicago (Ill.)')] }],
      'agent_functions' => [{ 'publish' => true, 'subjects' => [subject('Cataloging')] }],
      'agent_topics' => [{ 'publish' => true, 'subjects' => [subject('Library science')] }],
      'agent_resources' => [{ 'publish' => true, 'linked_agent_role' => 'creator', 'linked_resource' => 'Smith papers',
                              'file_uri' => 'https://example.edu/smith', 'linked_resource_description' => 'Held elsewhere.' },
                            { 'publish' => false, 'linked_agent_role' => 'creator', 'linked_resource' => 'Unpublished resource' }],
      'agent_alternate_sets' => [{ 'set_component' => 'VIAF 12345', 'file_uri' => 'https://viaf.org/viaf/12345' }],
      'notes' => [
        { 'jsonmodel_type' => 'note_bioghist', 'publish' => true, 'label' => 'Biography', 'subnotes' => [
          { 'jsonmodel_type' => 'note_abstract', 'content' => ['A librarian.'] },
          { 'jsonmodel_type' => 'note_text', 'publish' => true,
            'content' => "Born in <emph render=\"italic\">Urbana</emph> &amp; raised in Chicago.\n\nSee <extref xlink:href=\"https://example.edu\">the guide</extref>." },
          { 'jsonmodel_type' => 'note_text', 'publish' => false, 'content' => 'Staff-only remark.' },
          { 'jsonmodel_type' => 'note_chronology', 'publish' => true, 'title' => 'Timeline',
            'items' => [{ 'event_date' => '1900', 'events' => ['Born'] }, { 'event_date' => '1980', 'events' => ['Died'] }] },
          { 'jsonmodel_type' => 'note_orderedlist', 'publish' => true, 'title' => 'Degrees', 'enumeration' => 'arabic',
            'items' => ['B.A.', 'M.L.S.'] },
          { 'jsonmodel_type' => 'note_definedlist', 'publish' => true, 'items' => [{ 'label' => 'Spouse', 'value' => 'John Smith' }] },
          { 'jsonmodel_type' => 'note_outline', 'publish' => true, 'levels' => [{ 'items' => ['Top', { 'items' => ['Nested'] }] }] },
          { 'jsonmodel_type' => 'note_citation', 'content' => ['Who Was Who'], 'xlink' => { 'href' => 'https://example.edu/who' } }
        ] },
        { 'jsonmodel_type' => 'note_bioghist', 'publish' => false, 'label' => 'Legacy Archon ID',
          'subnotes' => [{ 'jsonmodel_type' => 'note_text', 'content' => 'UA Archon Instance::Creator Record ID 312' }] },
        { 'jsonmodel_type' => 'note_general_context', 'publish' => true,
          'subnotes' => [{ 'jsonmodel_type' => 'note_chronology', 'items' => [{ 'event_date' => '1950', 'events' => ['Event'] }] }] },
        { 'jsonmodel_type' => 'note_mandate', 'publish' => true, 'label' => 'Charter',
          'subnotes' => [{ 'jsonmodel_type' => 'note_text', 'content' => 'Chartered 1867.' }] },
        { 'jsonmodel_type' => 'note_legal_status', 'publish' => true,
          'subnotes' => [{ 'jsonmodel_type' => 'note_text', 'content' => 'Public body.' }] },
        { 'jsonmodel_type' => 'note_structure_or_genealogy', 'publish' => true,
          'subnotes' => [{ 'jsonmodel_type' => 'note_text', 'content' => 'Family tree.' }] }
      ],
      'related_agents' => [
        related('is_parent_of', 'agent_person', 'Smith, Junior'),
        related('is_parent_of', 'agent_family', 'Smith family'),
        related('is_associative_with', 'agent_corporate_entity', 'Hidden Society', publish: false),
        related('is_related_with', 'agent_person', 'Smith, Cousin').merge(
          'specific_relator' => 'cousin', 'description' => 'Corresponded.',
          'dates' => date('agent_relation', expression: '1930-1940', begin_std: '1930', end_std: '1940')
        )
      ]
    }
  end
end
