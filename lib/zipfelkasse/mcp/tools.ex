defmodule Zipfelkasse.MCP.Tools do
  @moduledoc """
  The MCP tools as `tools/list` shows them, and running them. All read except create_expense
  and create_reimbursement, which add entries; nothing can be changed or deleted. A result is
  JSON text (plain text for schema); a refused call returns its message as an error.
  """

  require Logger

  alias Zipfelkasse.{Activities, OrderedJSON, Split, Statistics}
  alias Zipfelkasse.MCP.{Arguments, ReadTools, ToolError, WriteTools}

  @max_rows 500
  @category_hint ~s[Use "none" for expenses without a category (statistics labels them "No category").]

  @read_only %{
    readOnlyHint: true,
    destructiveHint: false,
    idempotentHint: true,
    openWorldHint: false
  }
  @write %{
    readOnlyHint: false,
    destructiveHint: false,
    idempotentHint: false,
    openWorldHint: false
  }

  @doc "The most rows, entries or periods a tool returns."
  def max_rows, do: @max_rows

  @doc "The definitions of the tools, in their order; properties are keyword lists for `OrderedJSON`."
  def list do
    for tool <- tools() do
      properties = for {name, _type, schema, _opts} <- tool.properties, do: {name, schema}

      schema = %{
        type: "object",
        properties: if(properties == [], do: %{}, else: properties),
        additionalProperties: false
      }

      %{
        name: tool.name,
        title: tool.title,
        description: tool.description,
        inputSchema:
          if(tool[:required], do: Map.put(schema, :required, tool.required), else: schema),
        annotations: if(tool[:write], do: @write, else: @read_only)
      }
    end
  end

  @doc "The names of the tools."
  def names, do: Enum.map(tools(), & &1.name)

  @doc """
  Runs a tool on its arguments (decoded JSON, nil for none): `{text, error?}`, or `:unknown`.
  Option `:today`, the local date.
  """
  def call(name, arguments, opts \\ []) do
    case Enum.find(tools(), &(&1.name == name)) do
      nil -> :unknown
      tool -> run(tool, arguments, opts)
    end
  end

  defp run(tool, arguments, opts) do
    specs =
      Enum.map(tool.properties, fn {name, type, _schema, options} -> {name, type, options} end)

    case tool.run.(Arguments.decode!(arguments, specs), opts) do
      text when is_binary(text) -> {text, false}
      result -> {OrderedJSON.encode!(result), false}
    end
  rescue
    refusal in ToolError ->
      {refusal.message, true}

    error ->
      Logger.error(
        "MCP tool #{tool.name} failed: " <> Exception.format(:error, error, __STACKTRACE__)
      )

      {"Internal error while running the tool (details in the server log).", true}
  end

  defp tools do
    text =
      text_or_list(
        ~s[Substring of the title or notes (case-insensitive). A list matches if any of the terms ] <>
          ~s|occurs, e.g. ["Rewe", "Edeka", "Lidl"].|
      )

    read_tools(text) ++ write_tools()
  end

  defp read_tools(text) do
    [
      %{
        name: "balances",
        title: "Balances and settlement",
        description:
          "Current balance of each person in euros and a settlement proposal (who transfers how much to whom so " <>
            "that everyone ends at 0). Positive balance = is owed money, negative = owes money. Includes all " <>
            "non-deleted expenses and reimbursements.",
        properties: [],
        run: &ReadTools.balances/2
      },
      %{
        name: "balance_history",
        title: "Balance history",
        description:
          "Balance of each person at the end of each month (or week/year): how the balances developed over " <>
            "time. Based on the current data by expense date (later edits and deletions apply retroactively). " <>
            "Positive balance = is owed money, negative = owes money. Reimbursements count.",
        properties: [
          {:interval, {:choice, [:year, :month, :week]},
           choice(
             [:year, :month, :week],
             "Length of a period: month (default), week (ISO week) or year."
           ), []},
          {:from, :string,
           date("First period: the one containing this date. Default: the first expense."), []},
          {:to, :string, date("Last period: the one containing this date. Default: today."), []},
          {:person, :string, text("Name of a person: only their balance. Empty = everyone."), []}
        ],
        run: &ReadTools.balance_history/2
      },
      %{
        name: "search_expenses",
        title: "Search expenses",
        description:
          "Searches individual expenses (newest first unless sort says otherwise) with amount, payer and " <>
            "category; with detail=full also split (each person's share), notes and foreign currency. All " <>
            "filters are optional and are combined. Also returns the total number of matches, their total and " <>
            "– with person – the total of that person's shares. For plain totals by category/month, statistics " <>
            "is the better choice.",
        properties: [
          {:from, :string, date("First date (inclusive)."), []},
          {:to, :string, date("Last date (inclusive)."), []},
          {:category, :string, text(~s(Category name, e.g. "Lebensmittel". ) <> @category_hint),
           []},
          {:person, :string, text("Name of a person: finds expenses they paid OR take part in."),
           []},
          {:paid_by, :string, text("Name of a person: only expenses this person paid."), []},
          {:involved, :string,
           text("Name of a person: only expenses this person has a share in."), []},
          {:text, :text_or_list, text, []},
          {:min_amount, :number,
           number("Smallest amount in euros (inclusive), e.g. 50 or 12.5.", minimum: 0), []},
          {:max_amount, :number, number("Largest amount in euros (inclusive).", minimum: 0), []},
          {:reimbursements, {:choice, [:exclude, :include, :only]},
           choice(
             [:exclude, :include, :only],
             "Reimbursements (settlement payments between people): hide them (exclude, default), include " <>
               "them (include) or return only them (only)."
           ), []},
          {:sort, {:choice, sorts()},
           choice(
             sorts(),
             "Order of the expenses: date_desc (newest first, default), date_asc, amount_desc (most " <>
               "expensive first), amount_asc."
           ), []},
          {:detail, {:choice, [:compact, :full]},
           choice(
             [:compact, :full],
             "compact (default): id, date, title, category, payer and amount per expense. full: " <>
               "additionally split, each person's share, notes and foreign currency."
           ), []},
          {:limit, :integer, limit("Maximum number of expenses returned, default 50."), []}
        ],
        run: &ReadTools.search_expenses/2
      },
      %{
        name: "statistics",
        title: "Statistics",
        description:
          "Expense totals grouped by category, title (merchant), year, month (YYYY-MM), ISO week (YYYY-Www), " <>
            "person or category_month, optionally for a period. Without share_of: total amounts of the " <>
            "expenses. With share_of: only that person's share of each expense, i.e. what they consumed " <>
            ~s[themselves (e.g. "How much did I spend on restaurants in 2026?"). With group_by=person, amount ] <>
            "is each person's share (consumption) and paid is what they paid up front. year, month and week " <>
            "list periods without expenses with 0. compare=previous_year adds the amount of the same group one " <>
            "year earlier and the change. Reimbursements and deleted expenses never count.",
        properties: [
          {:group_by, {:choice, Statistics.groups()},
           choice(
             Statistics.groups(),
             "What to group by. title groups by expense title (case-insensitive), i.e. by merchant."
           ), [required: true]},
          {:from, :string, date("First date (inclusive)."), []},
          {:to, :string, date("Last date (inclusive)."), []},
          {:share_of, :string,
           text(
             "Name of a person: only their share counts (that person's perspective). Empty = total amounts."
           ), []},
          {:category, :string,
           text(
             "Only count expenses of this category (name, case-insensitive). " <> @category_hint
           ), []},
          {:text, :text_or_list, text, []},
          {:compare, {:choice, [:previous_year]},
           choice(
             [:previous_year],
             "previous_year: compare each row with the same group one year earlier (month 2026-03 with " <>
               "2025-03, category in from…to with from…to minus one year). For category, title and person, " <>
               "from is required."
           ), []},
          {:limit, :integer,
           limit("Maximum number of rows, default #{@max_rows}. total always covers all rows."),
           []}
        ],
        required: ["group_by"],
        run: &ReadTools.statistics/2
      },
      %{
        name: "activity",
        title: "Activity log",
        description:
          "Who created, changed or deleted which expense when, and other changes (settings, people, " <>
            "categories, rates, recurring expenses), newest first. Entries of expense_updated list the changed " <>
            "fields with old and new value (field names and values as shown in the app, in German).",
        properties: [
          {:from, :string, date("First day (inclusive, server time zone)."), []},
          {:to, :string, date("Last day (inclusive, server time zone)."), []},
          {:person, :string, text("Name of a person: only changes they made."), []},
          {:action, {:choice, Activities.actions()},
           choice(
             Activities.actions(),
             "Only this action, e.g. expense_created, expense_updated, expense_deleted, settings_updated."
           ), []},
          {:expense_id, :integer,
           integer("Only entries of this expense (id as in search_expenses).", 1), []},
          {:before_id, :integer,
           integer(
             "Paging: only entries with a smaller id (pass the id of the last entry of the previous page).",
             1
           ), []},
          {:limit, :integer, limit("Maximum number of entries, default 50."), []}
        ],
        run: &ReadTools.activity/2
      },
      %{
        name: "schema",
        title: "Database schema",
        description:
          "Explains the database tables and columns in words (amounts in cents, deleted expenses, " <>
            "reimbursements, shares, foreign currency), lists people and categories and returns the CREATE " <>
            "statements. Call before sql_query.",
        properties: [],
        run: &ReadTools.schema/2
      },
      %{
        name: "sql_query",
        title: "SQL query",
        description:
          "Runs exactly one read-only SQL query (SQLite dialect, only SELECT or WITH … SELECT) on a read-only " <>
            "copy of the data. Call schema first. Important: amounts are cents (divide by 100.0 for euros), " <>
            "exclude deleted expenses with deleted_at IS NULL, reimbursements (reimbursement = 1) are not " <>
            "expenses, a person's share is expense_shares.amount_cents; for case-insensitive text matches use " <>
            "title_folded and notes_folded. At most #{@max_rows} rows, aborted after 2 seconds, texts longer " <>
            "than 2000 characters are truncated. For standard questions, balances, search_expenses and " <>
            "statistics are simpler.",
        properties: [
          {:query, :string,
           text("The SQL query, e.g. SELECT name FROM participants WHERE archived_at IS NULL"),
           []}
        ],
        required: ["query"],
        run: &ReadTools.sql_query/2
      }
    ]
  end

  defp write_tools do
    amount =
      text_or_number(
        ~s[Amount in currency (default EUR) with a dot as decimal separator, e.g. "23.40".]
      )

    currency = text("ISO currency code, e.g. USD. Default EUR.")

    rate =
      number(
        "Only for a foreign currency: units of that currency per 1 EUR. Default: the ECB reference rate of the date.",
        exclusive_minimum: 0
      )

    duplicate = fn same ->
      flag(
        "Create it even if an entry with the same date, payer, amount and #{same} exists. Only set after " <>
          "asking the user."
      )
    end

    [
      %{
        name: "create_expense",
        title: "Create expense",
        description:
          "Creates an expense, as if the payer had entered it in the app. Ask the user before calling it if " <>
            "anything is unclear (amount, payer, who takes part); then tell them what was created. Without " <>
            "participants and weights, the amount is split equally among all active people. An entry with the " <>
            "same date, payer, amount and title is refused unless allow_duplicate is set. Settlement payments " <>
            "between people are not expenses: use create_reimbursement for them.",
        properties: [
          {:title, :string,
           text(
             ~s[What was bought, e.g. "Rewe" or "Pizza" (usually German, like the existing titles).]
           ), []},
          {:amount, :amount, amount, []},
          {:currency, :string, currency, []},
          {:fx_rate, :number, rate, []},
          {:date, :string, date("Date of the expense. Default today."), []},
          {:paid_by, :string, text("Name of the person who paid."), []},
          {:category, :string, text("Category name (case-insensitive). Empty = no category."),
           []},
          {:split, {:choice, Split.modes()},
           choice(
             Split.modes(),
             "equal (default): evenly among participants. shares, percent, amount: by the values in weights."
           ), []},
          {:participants, :strings,
           list_of_text(
             "Only for split=equal: names of the people the expense is for. Default: all active people."
           ), []},
          {:weights, :weights,
           map_of_text_or_number(
             ~s[For shares, percent and amount: person name → value, e.g. {"Anna": 2, "Ben": 1} (shares), ] <>
               ~s[{"Anna": 70, "Ben": 30} (percent, sum 100) or {"Anna": "15.00", "Ben": "8.40"} (amounts in ] <>
               "currency, sum = amount). These people are the participants."
           ), []},
          {:notes, :string, text("Optional note."), []},
          {:allow_duplicate, :boolean, duplicate.("title"), []}
        ],
        required: ["title", "amount", "paid_by"],
        write: true,
        run: &WriteTools.create_expense/2
      },
      %{
        name: "create_reimbursement",
        title: "Create reimbursement",
        description:
          "Records a settlement payment: from paid amount to to (e.g. a bank transfer to settle up). It " <>
            "changes the balances, but is not an expense. An entry with the same date, payer, amount and " <>
            "recipient is refused unless allow_duplicate is set.",
        properties: [
          {:from, :string, text("Name of the person who paid the money."), []},
          {:to, :string, text("Name of the person who received it."), []},
          {:amount, :amount, amount, []},
          {:currency, :string, currency, []},
          {:fx_rate, :number, rate, []},
          {:date, :string, date("Date of the payment. Default today."), []},
          {:notes, :string, text("Optional note."), []},
          {:allow_duplicate, :boolean, duplicate.("recipient"), []}
        ],
        required: ["from", "to", "amount"],
        write: true,
        run: &WriteTools.create_reimbursement/2
      }
    ]
  end

  defp sorts, do: [:date_desc, :date_asc, :amount_desc, :amount_asc]

  defp text(description), do: %{type: "string", description: description}

  defp date(description),
    do: text(description <> " Format YYYY-MM-DD (DD.MM.YYYY is accepted too).")

  defp choice(values, description),
    do: %{type: "string", description: description, enum: Enum.map(values, &Atom.to_string/1)}

  defp integer(description, minimum, maximum \\ nil) do
    %{type: "integer", description: description, minimum: minimum, maximum: maximum}
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp limit(description), do: integer(description, 1, @max_rows)

  defp number(description, opts) do
    %{
      type: "number",
      description: description,
      minimum: opts[:minimum],
      exclusiveMinimum: opts[:exclusive_minimum]
    }
    |> Map.reject(fn {_key, value} -> is_nil(value) end)
  end

  defp flag(description), do: %{type: "boolean", description: description}

  defp list_of_text(description),
    do: %{type: "array", description: description, items: %{type: "string"}}

  defp text_or_list(description),
    do: %{
      description: description,
      anyOf: [%{type: "string"}, %{type: "array", items: %{type: "string"}}]
    }

  defp text_or_number(description), do: %{type: ["string", "number"], description: description}

  defp map_of_text_or_number(description),
    do: %{
      type: "object",
      description: description,
      additionalProperties: %{type: ["string", "number"]}
    }
end
