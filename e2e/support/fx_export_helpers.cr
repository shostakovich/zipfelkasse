require "http/server"
require "http/client"

module E2E
  # An ECB endpoint whose behaviour a scenario controls: it forwards every
  # request to `upstream` (a FakeECB, exchangeable at any time) or fails with
  # `failure` (an HTTP status, or :empty for a valid XML file without rates).
  # Start a World with `env: {"ZIPFELKASSE_TEST_ECB_URL" => ecb.base_url}`.
  class SwitchableECB
    EMPTY_XML = %(<?xml version="1.0" encoding="UTF-8"?>\n<gesmes:Envelope xmlns:gesmes="http://www.gesmes.org/xml/2002-08-01" xmlns="http://www.ecb.int/vocabulary/2002-08-01/eurofxref">\n\t<Cube>\n\t</Cube>\n</gesmes:Envelope>\n)

    property upstream : FakeECB
    property failure : Int32 | Symbol | Nil = nil
    getter port : Int32
    @requests = [] of String
    @mutex = Mutex.new

    def initialize(@upstream : FakeECB)
      @server = HTTP::Server.new { |ctx| handle(ctx) }
      @port = @server.bind_tcp("127.0.0.1", 0).port
      spawn { @server.listen }
    end

    def base_url : String
      "http://127.0.0.1:#{@port}/"
    end

    def requests : Array(String)
      @mutex.synchronize { @requests.dup }
    end

    def count(file : String) : Int32
      requests.count(file)
    end

    def close : Nil
      @server.close
    end

    private def handle(ctx)
      file = ctx.request.path.lstrip('/')
      @mutex.synchronize { @requests << file }
      case f = @failure
      when Int32
        ctx.response.status_code = f
        ctx.response.print "kaputt"
      when :empty
        ctx.response.content_type = "text/xml"
        ctx.response.print EMPTY_XML
      else
        res = HTTP::Client.get(@upstream.base_url + file)
        ctx.response.status_code = res.status_code
        ctx.response.content_type = res.content_type || "application/octet-stream"
        ctx.response.write(res.body.to_slice)
      end
    end
  end

  # Helpers of the FX and export scenarios.
  module FxExport
    extend self

    # The number as the app writes it: shortest digits, no ".0".
    def shortest_float(v : Float64) : String
      s = v.to_s
      raise "unexpected exponent in #{s}" if s.includes?('e')
      s.ends_with?(".0") ? s[0...-2] : s
    end

    def shortest_float(s : String) : String
      shortest_float(s.to_f)
    end

    # A rate as the form shows it: shortest digits with a decimal comma.
    def german_rate(v : Float64 | String) : String
      shortest_float(v.is_a?(String) ? v.to_f : v).sub('.', ',')
    end

    # minor / 10^decimals / rate * 100, rounded half away from zero, in exactly
    # this order.
    def to_eur_cents(minor : Int64, decimals : Int32, rate : Float64) : Int64
      (minor.to_f / (10.0 ** decimals) / rate * 100).round(:ties_away).to_i64
    end

    def iso(t : Time) : String
      t.to_s("%Y-%m-%d")
    end

    def german(t : Time) : String
      t.to_s("%d.%m.%Y")
    end

    def day(s : String) : Time
      Time.parse_utc(s, "%Y-%m-%d")
    end

    # The ID of a row of `table` by name (participants, categories).
    def id_of(world : World, table : String, name : String) : Int64
      Snapshot.open(world.app.db_path) do |db|
        db.scalar("SELECT id FROM #{table} WHERE name = ?", name).as(Int64)
      end
    end

    def newest_expense_id(world : World) : Int64
      Snapshot.count(world.app.db_path, "SELECT max(id) FROM expenses")
    end

    # One row of the expenses table as strings.
    def expense_row(world : World, id : Int64) : Hash(String, String)
      Snapshot.open(world.app.db_path) do |db|
        db.query_one("SELECT amount_cents, original_amount_minor, original_currency, fx_rate, fx_source, date FROM expenses WHERE id = ?", id) do |rs|
          {
            "amount_cents" => rs.read(Int64).to_s, "original_amount_minor" => rs.read(Int64).to_s,
            "original_currency" => rs.read(String), "fx_rate" => shortest_float(rs.read(Float64)),
            "fx_source" => rs.read(String), "date" => rs.read(String),
          }
        end
      end
    end

    # The form of /ausgaben/neu. *whom* are participant IDs with their value
    # ("" for equal splits).
    def expense_form(title : String, date : String, amount : String, payer : Int64, whom : Hash(Int64, String),
                     currency = "EUR", other_currency = "", rate = "", rate_source = "", mode = "equal",
                     category : Int64? = nil, notes = "", reimbursement = false) : Array({String, String})
      form = [
        {"titel", title}, {"datum", date}, {"kategorie", category.to_s}, {"waehrung", currency},
        {"waehrung_andere", other_currency}, {"betrag", amount}, {"kurs", rate}, {"kurs_quelle", rate_source},
        {"bezahlt_von", payer.to_s}, {"notiz", notes}, {"aufteilung", mode},
      ]
      form << {"rueckzahlung", "1"} if reimbursement
      whom.each do |id, value|
        form << {"teil", id.to_s}
        form << {"wert_#{id}", value}
      end
      form
    end

    # Value of an input (by id) of a page.
    def input_value(r : Response, id : String) : String?
      r.doc.xpath_node(%(//input[@id="#{id}"])).try(&.["value"]?)
    end

    # Rows of the tables of a page section (by card title) as cell texts.
    def table_rows(r : Response, card_title : String) : Array(Array(String))
      section = r.doc.xpath_node(%(//section[.//*[contains(@class, "card-title")][normalize-space(.)="#{card_title}"]]))
      return [] of Array(String) unless section
      section.xpath_nodes(".//tbody/tr").map do |tr|
        tr.xpath_nodes("./td").map(&.content.gsub(/\s+/, " ").strip)
      end
    end
  end
end
