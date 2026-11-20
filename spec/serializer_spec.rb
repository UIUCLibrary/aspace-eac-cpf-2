# frozen_string_literal: true

require_relative 'support/rich_agent'

RSpec.describe EacCpf2::Serializer do
  REAL_AGENTS = Dir[File.expand_path('fixtures/agents/*.json', __dir__)].map { |f| File.basename(f, '.json') }.sort

  describe 'schema validity' do
    REAL_AGENTS.each do |name|
      it "produces valid EAC-CPF 2.0 for #{name}" do
        expect(schema_errors(export(fixture(name)))).to be_empty
      end
    end

    it 'produces valid EAC-CPF 2.0 when every supported field is populated' do
      records = [{ 'uri' => '/repositories/2/resources/1', 'title' => 'Papers', 'jsonmodel_type' => 'resource',
                   'role' => 'creator', 'relator' => 'aut', 'ead_id' => 'UA.1.2.3' }]
      expect(schema_errors(export(RichAgent.agent, records: records, agency_code: 'IU'))).to be_empty
    end
  end

  # ArchivesSpace's own exporter writes these as EAC-CPF 2010
  # hierarchical-child / temporal-earlier, which reads the other way round.
  describe 'relation direction' do
    it 'keeps a subordinate body subordinate to its parent' do
      doc = export(fixture('corporate_entities_1338'))

      expect(relation_types(doc)).to eq [['is or was subordinate to', 'University of Illinois at Urbana-Champaign. Office of the Chancellor']]
    end

    it 'reads earlier and later names from the described body to the other' do
      earlier = export(fixture('corporate_entities_1874'))
      later = export(fixture('corporate_entities_2016'))

      expect(relation_types(earlier)).to include(['has successor', 'University of Illinois at Urbana-Champaign. Center for Advanced Computation'])
      expect(relation_types(later)).to include(['is successor of', 'University of Illinois at Urbana-Champaign. Department of Computer Science'])
    end

    it 'reads parent and child from the described person to the other' do
      expect(relation_types(export(fixture('people_3163')))).to include(['is child of', 'Kliger, Paul I.'])
      expect(relation_types(export(fixture('people_3189')))).to eq [['has child', 'McGrann, John']]
    end

    it 'identifies the RiC-O property and keeps the ArchivesSpace relator' do
      type = export(fixture('corporate_entities_1338')).at_xpath('//eac:relation/eac:relationType', NS)

      expect(type['valueURI']).to eq 'https://www.ica.org/standards/RiC/ontology#isOrWasSubordinateTo'
      expect(type['localType']).to eq 'is_subordinate_to'
    end

    it 'drops the RiC-O property when its person-only domain is not met' do
      types = export(RichAgent.agent).xpath('//eac:relationType[@localType="is_parent_of"]', NS)

      expect(types.map { |t| [t.text, t['valueURI']] }).to eq [
        ['has child', 'https://www.ica.org/standards/RiC/ontology#hasChild'],
        ['has child', nil]
      ]
    end
  end

  describe 'unpublished data' do
    let(:xml) { export(RichAgent.agent).to_xml }

    it 'leaves out unpublished notes, such as the Legacy Archon ID notes migrated from Archon' do
      REAL_AGENTS.each do |name|
        expect(export(fixture(name)).to_xml).not_to include('Archon Instance'), name
      end
      expect(xml).not_to include('Legacy Archon ID')
    end

    it 'leaves out unpublished subnotes, sub-records, subjects and related agents' do
      expect(xml).not_to include('Staff-only remark')
      expect(xml).not_to include('Unpublished Place')
      expect(xml).not_to include('Hidden term')
      expect(xml).not_to include('Unpublished resource')
      expect(xml).not_to include('Hidden Society')
    end

    it 'never exports contact details' do
      expect(xml).not_to include('secret@example.edu')
    end

    # Krista's example on UIUCLibrary/arclight#88 (person 3012 on dev, 3015 on
    # stage): an agent migrated from Archon whose only note is the unpublished
    # Legacy Archon ID, related to both a person and a corporate body.
    it 'gives an agent whose only note is unpublished no biographical history, and keeps its relations' do
      doc = export(fixture('people_3015'))

      expect(doc.xpath('//eac:biogHist', NS)).to be_empty
      expect(doc.to_xml).not_to include('Archon')
      expect(doc.xpath('//eac:relation/eac:targetEntity', NS).map { |t| [t['targetType'], t.at_xpath('eac:part', NS).text] }).to eq [
        ['person', 'Gregory, Louisa Allen'],
        ['corporateBody', 'University of Illinois at Urbana-Champaign. Office of the University President']
      ]
      expect(doc.at_xpath('//eac:relation/eac:descriptiveNote/eac:p', NS).text)
        .to eq 'John Milton Gregory was the Husband of Louisa Allen Gregory.'
    end
  end

  it 'adds no whitespace around markup inside paragraphs' do
    xml = export(RichAgent.agent).to_xml(save_with: Nokogiri::XML::Node::SaveOptions::AS_XML)
    raw = EacCpf2::Serializer.new(agent: EacCpf2::Publication.filter_agent(RichAgent.agent)).to_xml

    expect(raw).to include('Born in <span localType="emph" style="font-style: italic">Urbana</span> &amp; raised')
    expect(xml).to include('Born in <span')
  end

  describe 'names' do
    it 'carries the exact ArchivesSpace heading alongside the name parts' do
      entry = export(fixture('corporate_entities_1539')).at_xpath('//eac:identity/eac:nameEntry', NS)

      expect(entry['aspace:sortName']).to eq 'University of Illinois at Urbana-Champaign. Office of the Chancellor'
      expect(entry['status']).to eq 'authorized'
      expect(entry['preferredForm']).to eq 'true'
    end

    it 'groups parallel names into a nameEntrySet' do
      set = export(RichAgent.agent).at_xpath('//eac:identity/eac:nameEntrySet', NS)

      expect(set.xpath('eac:nameEntry/@aspace:sortName', NS).map(&:value)).to eq ['Smith, Jane, 1900-1980', 'Смит, Джейн']
      expect(set.at_xpath('eac:nameEntry[2]/@languageOfElement', NS).value).to eq 'rus'
    end
  end

  describe 'linked records' do
    it 'carries the EAD ID of a linked collection so consumers need not look it up' do
      records = [{ 'uri' => '/repositories/7/resources/5246', 'title' => 'Mailing Services Publications',
                   'jsonmodel_type' => 'resource', 'role' => 'creator', 'ead_id' => 'UA.24.1.3' }]
      target = export(fixture('corporate_entities_1338'), records: records, base_url: 'https://aspace.example.edu/')
               .at_xpath('//eac:targetEntity[@targetType="resource"]', NS)

      expect(target['valueURI']).to eq 'https://aspace.example.edu/repositories/7/resources/5246'
      expect(target['aspace:eadId']).to eq 'UA.24.1.3'
      expect(target.at_xpath('../eac:relationType', NS)['localType']).to eq 'creator'
    end
  end

  it 'reduces markup in linked record titles to text' do
    records = [{ 'uri' => '/repositories/2/resources/9', 'title' => '<emph render="italic">ALSC Newsletter</emph> & Notes',
                 'jsonmodel_type' => 'resource', 'role' => 'creator' }]
    part = export(fixture('people_16'), records: records).at_xpath('//eac:targetEntity[@targetType="resource"]/eac:part', NS)

    expect(part.text).to eq 'ALSC Newsletter & Notes'
  end

  describe 'control' do
    it 'synthesizes the required maintenance history when ArchivesSpace has none' do
      events = export(fixture('corporate_entities_1338')).xpath('//eac:maintenanceEvent', NS)

      expect(events.map { |e| e['maintenanceEventType'] }).to eq %w[created updated]
      expect(events.first.at_xpath('eac:agent', NS).text).to eq 'ArchivesSpace'
    end

    it 'records the ArchivesSpace URI for consumers that key on it' do
      id = export(fixture('people_16')).at_xpath('//eac:otherRecordId[@localType="archivesspace_uri"]', NS)

      expect(id.text).to eq '/agents/people/16'
    end
  end
end
