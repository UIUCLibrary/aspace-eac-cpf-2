#!/usr/bin/env ruby
# frozen_string_literal: true

# Fetches EAC-CPF 2.0 for agents from a running ArchivesSpace with this plugin
# installed and validates each document against the vendored schema.
#
#   BUNDLE_GEMFILE=spec/Gemfile bundle exec ruby scripts/validate_live.rb \
#     --url http://localhost:8089 --user admin [--sample 200] [URI ...]
#
# The password is read from ASPACE_PASSWORD, or prompted for. With no URIs, a
# random sample of agents of each type is checked.

require 'io/console'
require 'json'
require 'net/http'
require 'nokogiri'
require 'optparse'
require 'uri'

options = { url: 'http://localhost:8089', user: 'admin', sample: 200 }
OptionParser.new do |opts|
  opts.on('--url URL') { |v| options[:url] = v }
  opts.on('--user USER') { |v| options[:user] = v }
  opts.on('--sample N', Integer) { |v| options[:sample] = v }
end.parse!

base = URI(options[:url])
http = Net::HTTP.start(base.host, base.port, use_ssl: base.scheme == 'https', read_timeout: 300)
password = ENV.fetch('ASPACE_PASSWORD') do
  print 'Password: '
  $stdin.noecho(&:gets).to_s.chomp.tap { puts }
end
login = http.post("/users/#{options[:user]}/login", URI.encode_www_form(password: password))
abort "Login failed: HTTP #{login.code}" unless login.code == '200'
session = JSON.parse(login.body)['session']

get = lambda do |path|
  request = Net::HTTP::Get.new(path)
  request['X-ArchivesSpace-Session'] = session
  http.request(request)
end

uris = ARGV.dup
if uris.empty?
  %w[people corporate_entities families].each do |type|
    ids = JSON.parse(get.call("/agents/#{type}?all_ids=true").body)
    uris.concat(ids.sample((options[:sample] / 3) + 1).map { |id| "/agents/#{type}/#{id}" })
  end
end

schema = Nokogiri::XML::Schema(File.open(File.expand_path('../schema/eac-cpf-2.0/eac.xsd', __dir__)))
counts = Hash.new(0)
slowest = []

uris.each do |uri|
  started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  response = get.call("#{uri}/eac_cpf_2.xml")
  elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
  slowest = (slowest << [elapsed, uri]).max(5)

  case response.code
  when '404'
    counts[:unpublished] += 1
  when '200'
    errors = schema.validate(Nokogiri::XML(response.body.force_encoding('UTF-8')))
    if errors.empty?
      counts[:valid] += 1
    else
      counts[:invalid] += 1
      puts "INVALID #{uri}: #{errors.first(3).map(&:message).join(' | ')}"
    end
  else
    counts[:error] += 1
    puts "HTTP #{response.code} #{uri}: #{response.body[0, 300]}"
  end
end

puts "Checked #{uris.length}: #{counts.map { |k, v| "#{v} #{k}" }.join(', ')}"
puts "Slowest: #{slowest.map { |s, u| format('%<u>s %<s>.2fs', u: u, s: s) }.join(', ')}"
exit(counts[:invalid].zero? && counts[:error].zero? ? 0 : 1)
