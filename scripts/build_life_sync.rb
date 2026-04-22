#!/usr/bin/env ruby
# frozen_string_literal: true

require "cgi"
require "date"
require "json"
require "fileutils"
require "open-uri"
require "rss"
require "time"

ROOT = File.expand_path("..", __dir__)

defaults = {
  output: File.join(ROOT, "life", "data", "life-sync.json"),
  date: Date.today.to_s
}

options = defaults.dup

argv = ARGV.dup
until argv.empty?
  flag = argv.shift
  value = argv.shift
  case flag
  when "--output"
    options[:output] = File.expand_path(value)
  when "--date"
    options[:date] = value
  else
    abort("Unknown option: #{flag}")
  end
end

def fetch(url)
  URI.open(url, "User-Agent" => "Mozilla/5.0 PiùMossoLifeBot/1.0").read
rescue StandardError
  ""
end

def clean_html(text)
  CGI.unescapeHTML(
    text.to_s
      .gsub(/<br\s*\/?>/i, " ")
      .gsub(/<\/?[^>]+>/, " ")
      .gsub(/\s+/, " ")
      .strip
  )
end

def absolute_url(base, href)
  return href if href.to_s.start_with?("http://", "https://")
  return "" if href.to_s.empty?

  URI.join(base, href).to_s
end

def rss_items(url, limit: 6)
  xml = fetch(url)
  return [] if xml.empty?

  feed = RSS::Parser.parse(xml, false)
  return [] unless feed.respond_to?(:items)

  feed.items.first(limit).map do |item|
    {
      title: clean_html(item.title),
      link: item.link.to_s,
      published_at: item.respond_to?(:pubDate) ? item.pubDate&.to_s : nil
    }
  end
rescue StandardError
  []
end

def parse_poznan_events(date, limit: 10)
  url = "https://www.poznan.pl/mim/events/#{date}/?sort=new&count=20"
  html = fetch(url)
  return [] if html.empty?

  blocks = html.scan(/<article class="event-box".*?<\/article>/m)
  blocks.first(limit).map do |block|
    times = block.scan(/<time>\s*([^<]+)\s*<\/time>/m).flatten.map { |item| clean_html(item) }
    href = block[/<a href="([^"]+)" class="description-event-title-link">/m, 1]
    title = clean_html(block[/<h2[^>]*description-event-title[^>]*>(.*?)<\/h2>/m, 1])
    category = clean_html(block[/description-event-category-link">([^<]+)<\/a>/m, 1])
    place = clean_html(block[/<div class="dotdotdot description-event-place">.*?\n(.*?)\n<\/div>/m, 1])

    next if title.empty?

    {
      title: title,
      time: times.last.to_s,
      date: times.first.to_s,
      category: category,
      place: place,
      url: absolute_url("https://www.poznan.pl", href)
    }
  end.compact
rescue StandardError
  []
end

def parse_cinema(limit: 12)
  html = fetch("https://poznan.repertuary.pl/cinema_program/by_hour")
  return [] if html.empty?

  sections = html.scan(/<h3>\s*([0-9]{1,2}:[0-9]{2}).*?<\/h3>(.*?)(?=<tr>\s*<th colspan="4">\s*<h3>|<\/table>)/m)
  results = []

  sections.each do |time, body|
    body.scan(/<td class="cinema">.*?<a[^>]+href="([^"]+)".*?>(.*?)<\/a>.*?<td>\s*<a[^>]+href="([^"]+)".*?>(.*?)<\/a>/m) do |cinema_href, cinema_name, film_href, film_name|
      results << {
        time: clean_html(time),
        cinema: clean_html(cinema_name),
        title: clean_html(film_name),
        cinema_url: absolute_url("https://poznan.repertuary.pl", cinema_href),
        film_url: absolute_url("https://poznan.repertuary.pl", film_href)
      }
      break if results.length >= limit
    end
    break if results.length >= limit
  end

  results
rescue StandardError
  []
end

MARKET_SYMBOLS = {
  "wig20" => { name: "WIG20", stooq: "wig20" },
  "mwig40" => { name: "mWIG40", stooq: "mwig40" },
  "spx" => { name: "S&P 500", stooq: "^spx" },
  "ndq" => { name: "Nasdaq 100", stooq: "^ndq" },
  "usdpln" => { name: "USD/PLN", stooq: "usdpln" },
  "xauusd" => { name: "Gold", stooq: "xauusd" },
  "btcusd" => { name: "BTC/USD", stooq: "btcusd" }
}.freeze

def fetch_quote(symbol)
  payload = fetch("https://stooq.com/q/l/?s=#{CGI.escape(symbol)}").strip
  parts = payload.split(",")
  return nil if parts.length < 7
  return nil if parts[1] == "N/D"

  open = parts[3].to_f
  close = parts[6].to_f
  high = parts[4].to_f
  low = parts[5].to_f
  change_pct = open.positive? ? (((close - open) / open) * 100.0) : 0.0

  {
    symbol: parts[0],
    date: parts[1],
    time: parts[2],
    open: open,
    high: high,
    low: low,
    close: close,
    changePct: change_pct.round(2)
  }
rescue StandardError
  nil
end

def build_market_snapshot
  quotes = MARKET_SYMBOLS.each_with_object({}) do |(key, config), memo|
    quote = fetch_quote(config[:stooq])
    memo[key] = quote&.merge(name: config[:name])
  end

  risk_score = 0
  risk_score += 2 if quotes.dig("spx", :changePct).to_f > 0.35
  risk_score += 2 if quotes.dig("ndq", :changePct).to_f > 0.45
  risk_score += 1 if quotes.dig("btcusd", :changePct).to_f > 1.0
  risk_score += 1 if quotes.dig("wig20", :changePct).to_f > 0.4
  risk_score += 1 if quotes.dig("mwig40", :changePct).to_f > 0.4
  risk_score -= 1 if quotes.dig("usdpln", :changePct).to_f > 0.35
  risk_score -= 1 if quotes.dig("xauusd", :changePct).to_f > 0.8
  risk_score -= 2 if quotes.dig("spx", :changePct).to_f < -0.45
  risk_score -= 2 if quotes.dig("ndq", :changePct).to_f < -0.6
  risk_score -= 1 if quotes.dig("btcusd", :changePct).to_f < -1.4

  regime =
    if risk_score >= 3
      "risk-on"
    elsif risk_score >= 1
      "selective"
    else
      "defensive"
    end

  posture =
    case regime
    when "risk-on"
      "Rynek premiuje odwagę bardziej niż defensywę, ale nadal nie warto gonić ruchu bez planu."
    when "selective"
      "To nie jest dzień na szeroką euforię. Lepiej działa selekcja, jakość i czekanie na potwierdzenie."
    else
      "Kapitał robi się ostrożny. Dziś większą przewagą może być cierpliwość niż aktywność."
    end

  ideas =
    case regime
    when "risk-on"
      [
        "Patrz na mocne trendy, ale tylko tam, gdzie rynek już pokazał popyt.",
        "Nie zwiększaj ryzyka tylko dlatego, że świeci się na zielono.",
        "Premiowane mogą być wzrost i momentum, ale wciąż z twardym planem wyjścia."
      ]
    when "selective"
      [
        "Lepiej działa selektywność niż szerokie kupowanie wszystkiego.",
        "Szukaj jakości i klarownej przewagi zamiast samego hałasu newsowego.",
        "Jeśli nie ma tezy, najlepszym ruchem bywa obserwacja."
      ]
    else
      [
        "Broni się gotówka, cierpliwość i redukcja impulsów.",
        "Defensywa ma sens tylko wtedy, gdy widzisz realny stres w danych i newsach.",
        "Nie myl aktywności z przewagą. Dziś może wygrywać dyscyplina."
      ]
    end

  {
    generatedAt: Time.now.iso8601,
    regime: regime,
    score: risk_score,
    posture: posture,
    ideas: ideas,
    quotes: quotes
  }
end

KEYWORD_THEMES = {
  "geopolityka" => /war|missile|attack|iran|russia|ukraine|gaza|israel|sudan|china sea/i,
  "stopy i inflacja" => /inflation|rate|mortgage|cost|price|bank|fed|ecb|economy|tariff|trade/i,
  "polityka i władza" => /government|minister|strike|budget|election|parliament|tax|policy|starmer|trump/i
}.freeze

def build_news_snapshot
  world = rss_items("https://feeds.bbci.co.uk/news/world/rss.xml")
  business = rss_items("https://feeds.bbci.co.uk/news/business/rss.xml")
  politics = rss_items("https://feeds.bbci.co.uk/news/politics/rss.xml")

  titles = (world + business + politics).map { |item| item[:title].to_s }
  themes = KEYWORD_THEMES.map do |label, regex|
    count = titles.count { |title| title.match?(regex) }
    next if count.zero?
    { label: label, count: count }
  end.compact.sort_by { |item| -item[:count] }.first(3)

  {
    world: world,
    business: business,
    politics: politics,
    themes: themes
  }
end

def score_event(event)
  score = 0
  score += 4 if event[:category].match?(/Muzyka|Sztuka|Film|Teatr/i)
  score += 2 if event[:place].match?(/CK Zamek|Muza|Muzeum|Teatr/i)
  score += 1 if event[:time].match?(/1[7-9]:|20:|21:/)
  score
end

def build_daily_plan(events:, cinema:, market:, news:)
  top_events = events.sort_by { |event| -score_event(event) }.first(4)
  evening_cinema = cinema.select { |item| item[:time] >= "17:00" }.first(4)
  evening_cinema = cinema.first(4) if evening_cinema.empty?

  summary =
    if top_events.any?
      "Masz dziś konkretne opcje: #{top_events.first[:title]} o #{top_events.first[:time]}, a później możesz domknąć dzień kinem albo spokojniejszą wystawą."
    else
      "Dziś najlepiej zacząć od jednego klimatu dnia i wejść przez Finder, bo nie mam pełnej listy miejskich wydarzeń."
    end

  actions = []
  actions << "Miasto: sprawdź #{top_events.first[:title]} (#{top_events.first[:time]}, #{top_events.first[:place]})" if top_events.first
  actions << "Wieczór: rozważ kino #{evening_cinema.first[:title]} o #{evening_cinema.first[:time]} w #{evening_cinema.first[:cinema]}" if evening_cinema.first
  actions << "Rynek: dziś dominuje tryb #{market[:regime]} — #{market[:posture].downcase}"
  if news[:themes].any?
    actions << "Świat: najmocniej przebijają się tematy #{news[:themes].map { |item| item[:label] }.join(', ')}"
  end

  {
    summary: summary,
    actions: actions.first(4),
    cityPicks: top_events,
    cinemaPicks: evening_cinema
  }
end

date = options[:date]
events = parse_poznan_events(date)
cinema = parse_cinema
market = build_market_snapshot
news = build_news_snapshot
daily = build_daily_plan(events: events, cinema: cinema, market: market, news: news)

snapshot = {
  generatedAt: Time.now.iso8601,
  date: date,
  daily: daily,
  city: {
    events: events,
    cinema: cinema
  },
  market: market,
  news: news,
  sources: {
    poznanEvents: "https://www.poznan.pl/mim/events/#{date}/?sort=new&count=20",
    cinema: "https://poznan.repertuary.pl/cinema_program/by_hour",
    world: "https://feeds.bbci.co.uk/news/world/rss.xml",
    business: "https://feeds.bbci.co.uk/news/business/rss.xml",
    politics: "https://feeds.bbci.co.uk/news/politics/rss.xml"
  }
}

FileUtils.mkdir_p(File.dirname(options[:output]))
File.write(options[:output], JSON.pretty_generate(snapshot))

puts "Life sync snapshot written to #{options[:output]}"
