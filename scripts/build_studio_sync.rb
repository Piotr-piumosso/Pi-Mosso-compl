#!/usr/bin/env ruby
# frozen_string_literal: true

require "csv"
require "json"
require "fileutils"
require "time"

ROOT = File.expand_path("..", __dir__)

defaults = {
  lead_machine: "/Users/piotrgorski/Documents/GitHub/lead-machine",
  engine: "/Users/piotrgorski/Documents/GitHub/piumosso-engine",
  output: File.join(ROOT, "studio", "data", "studio-sync.json")
}

options = defaults.dup

argv = ARGV.dup
until argv.empty?
  flag = argv.shift
  value = argv.shift
  case flag
  when "--lead-machine"
    options[:lead_machine] = File.expand_path(value)
  when "--engine"
    options[:engine] = File.expand_path(value)
  when "--output"
    options[:output] = File.expand_path(value)
  else
    abort("Unknown option: #{flag}")
  end
end

def read_csv(path)
  return [] unless File.exist?(path)

  CSV.read(path, headers: true).map(&:to_h)
rescue CSV::MalformedCSVError
  lines = File.read(path).split(/\r?\n/).reject(&:empty?)
  header = lines.shift.to_s.split(",")
  lines.map do |line|
    values = line.split(",")
    header.each_with_index.to_h { |key, index| [key, values[index].to_s.strip] }
  end
end

def read_json(path)
  return {} unless File.exist?(path)

  JSON.parse(File.read(path))
rescue JSON::ParserError
  {}
end

lead_machine = options[:lead_machine]
engine = options[:engine]

baza = read_csv(File.join(lead_machine, "data", "baza_glowna.csv"))
nowe = read_csv(File.join(lead_machine, "data", "nowe_rekordy.csv"))
engine_leads = read_csv(File.join(engine, "data", "leads.csv"))
sent = read_csv(File.join(engine, "data", "sent_log.csv"))
lead_state = read_json(File.join(lead_machine, "data", "state.json"))
send_state = read_json(File.join(engine, "data", "send_state.json"))

generated_at = [
  lead_state["last_run"],
  send_state["last_run"],
  Time.now.iso8601
].compact.max

snapshot = {
  generatedAt: generated_at,
  sourceStats: {
    baza: baza.length,
    nowe: nowe.length,
    engine: engine_leads.length,
    sent: sent.length
  },
  sourceRuns: {
    lead_machine_last_run: lead_state["last_run"],
    lead_machine_added_rows: lead_state["added_rows"],
    engine_last_run: send_state["last_run"],
    engine_attempted: send_state["attempted"],
    engine_sent: send_state["sent"]
  },
  dataHub: {
    baza: baza,
    nowe: nowe,
    engine: engine_leads,
    sent: sent
  }
}

FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], JSON.pretty_generate(snapshot))

puts "Studio sync snapshot written to #{options[:output]}"
