require_relative "lib/notes"

app = Notes::App.new(Notes.connect_db, Redis.new(url: Notes::CONFIG[:redis_url]), Notes::CONFIG[:redis_prefix])
server = app.server(Notes::CONFIG[:port])
trap("INT") { server.shutdown }
puts "notes API on http://localhost:#{Notes::CONFIG[:port]}"
server.start
