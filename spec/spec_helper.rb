# frozen_string_literal: true

require 'json'
require_relative '../backend/lib/eac_cpf2'

module SpecHelpers
  SCHEMA = Nokogiri::XML::Schema(File.open(File.expand_path('../schema/eac-cpf-2.0/eac.xsd', __dir__)))
  NS = { 'eac' => EacCpf2::Serializer::NAMESPACE, 'aspace' => EacCpf2::Serializer::EXTENSION_NAMESPACE }.freeze

  def fixture(name)
    JSON.parse(File.read(File.expand_path("fixtures/agents/#{name}.json", __dir__)))
  end

  def export(agent, records: [], **opts)
    xml = EacCpf2::Serializer.new(agent: EacCpf2::Publication.filter_agent(agent), records: records, **opts).to_xml
    Nokogiri::XML(xml)
  end

  def schema_errors(doc)
    SCHEMA.validate(doc).map(&:message)
  end

  def relation_types(doc)
    doc.xpath('//eac:relation', NS).map do |rel|
      [rel.at_xpath('eac:relationType[1]', NS).text, rel.at_xpath('eac:targetEntity/eac:part', NS).text]
    end
  end
end

NS = SpecHelpers::NS

RSpec.configure do |config|
  config.include SpecHelpers
  config.disable_monkey_patching!
end
