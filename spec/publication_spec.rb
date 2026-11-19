# frozen_string_literal: true

RSpec.describe EacCpf2::Publication do
  describe '.record_published?' do
    it 'requires a linked record to be published, unsuppressed and without unpublished ancestors' do
      expect(described_class.record_published?('publish' => true)).to be true
      expect(described_class.record_published?('publish' => false)).to be false
      expect(described_class.record_published?('publish' => true, 'suppressed' => true)).to be false
      expect(described_class.record_published?('publish' => true, 'has_unpublished_ancestor' => true)).to be false
    end
  end

  describe '.filter_agent' do
    it 'keeps subnotes that inherit publication from their note' do
      note = { 'jsonmodel_type' => 'note_bioghist', 'publish' => true,
               'subnotes' => [{ 'jsonmodel_type' => 'note_citation', 'content' => ['Kept'] },
                              { 'jsonmodel_type' => 'note_text', 'publish' => false, 'content' => 'Dropped' }] }

      filtered = described_class.filter_agent('notes' => [note])

      expect(filtered['notes'].first['subnotes'].map { |s| Array(s['content']).join }).to eq ['Kept']
    end

    it 'does not modify the record it is given' do
      agent = { 'notes' => [{ 'publish' => false }], 'agent_contacts' => [{}] }

      described_class.filter_agent(agent)

      expect(agent).to eq('notes' => [{ 'publish' => false }], 'agent_contacts' => [{}])
    end
  end
end
