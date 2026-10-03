module Zipfelkasse::Web
  module Views
    record ListRow, id : Int64, name : String, expenses : Int32, balance : Int64 = 0, first : Bool = false, last : Bool = false

    record RenameForm, action : String, row : ListRow do
      Web.view "web/rename_form.ecr"
    end

    record ArchivedRows, action : String, anchor : String, rows : Array(ListRow) do
      Web.view "web/archived_rows.ecr"
    end

    # group_name is the input as entered (after an error).
    record Settings, group_name : String do
      Web.view "web/settings.ecr"
    end

    # name is the "new person" input after an error.
    record Participants, active : Array(ListRow), archived : Array(ListRow), name : String, me : Store::Participant do
      Web.view "web/participants.ecr"
    end

    # name is the "new category" input after an error.
    record Categories, active : Array(ListRow), archived : Array(ListRow), name : String do
      Web.view "web/categories.ecr"
    end
  end

  class SettingsController < Controller
    PARTICIPANTS = "/einstellungen/teilnehmer"
    CATEGORIES   = "/einstellungen/kategorien"

    def register : Nil
      get("/einstellungen") { |env| show_settings(env, @d.store.group_name) }
      post("/einstellungen") { |env| save_settings(env) }

      get(PARTICIPANTS) { |env| show_participants(env) }
      post(PARTICIPANTS) { |env| create_participant(env) }
      post("#{PARTICIPANTS}/:id") { |env| rename_participant(env) }
      post("#{PARTICIPANTS}/:id/archivieren") { |env| archive_participant(env, true) }
      post("#{PARTICIPANTS}/:id/reaktivieren") { |env| archive_participant(env, false) }

      get(CATEGORIES) { |env| show_categories(env) }
      post(CATEGORIES) { |env| create_category(env) }
      post("#{CATEGORIES}/:id") { |env| rename_category(env) }
      post("#{CATEGORIES}/:id/archivieren") { |env| archive_category(env, true) }
      post("#{CATEGORIES}/:id/reaktivieren") { |env| archive_category(env, false) }
      post("#{CATEGORIES}/:id/hoch") { |env| move_category(env, true) }
      post("#{CATEGORIES}/:id/runter") { |env| move_category(env, false) }
    end

    private def show_settings(env : HTTP::Server::Context, group_name : String, status = 200, error : String? = nil) : String
      page(env, Views::Settings.new(group_name), "Einstellungen", Nav::Settings, status, error)
    end

    private def save_settings(env : HTTP::Server::Context) : String
      @d.store.set_group_name(env.me.id, env.form("gruppenname"))
      redirect(env, "/einstellungen", "Gespeichert.")
    rescue ex : Domain::ValidationError
      show_settings(env, env.form("gruppenname"), 422, ex.msg)
    end

    private def show_participants(env : HTTP::Server::Context, name = "", status = 200, error : String? = nil) : String
      balances = @d.store.balances
      counts = @d.store.expense_count_by_participant
      archived, active = @d.store.list_participants(true).partition(&.archived?).map do |people|
        people.map { |p| Views::ListRow.new(p.id, p.name, counts.fetch(p.id, 0), balances.fetch(p.id, 0_i64)) }
      end
      page(env, Views::Participants.new(active, archived, name, env.me), "Teilnehmer", Nav::Settings, status, error)
    end

    private def create_participant(env : HTTP::Server::Context) : String
      @d.store.create_participant(env.me.id, env.form("name"))
      redirect(env, PARTICIPANTS, "„#{Store.normalize_name(env.form("name"))}“ hinzugefügt.")
    rescue ex : Domain::ValidationError
      show_participants(env, env.form("name"), 422, ex.msg)
    end

    private def rename_participant(env : HTTP::Server::Context) : String
      @d.store.rename_participant(env.me.id, find_participant(env).id, env.form("name"))
      redirect(env, PARTICIPANTS, "Gespeichert.")
    rescue ex : Domain::ValidationError
      show_participants(env, "", 422, ex.msg)
    end

    # The store refuses to archive a person with an open balance.
    private def archive_participant(env : HTTP::Server::Context, archive : Bool) : String
      person = find_participant(env)
      @d.store.set_participant_archived(env.me.id, person.id, archive)
      redirect(env, PARTICIPANTS, "„#{person.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
    rescue ex : Domain::ValidationError
      show_participants(env, "", 422, ex.msg)
    end

    private def find_participant(env : HTTP::Server::Context) : Store::Participant
      or_404(env, "Person nicht gefunden.") { @d.store.get_participant(path_id(env)) }
    end

    private def show_categories(env : HTTP::Server::Context, name = "", status = 200, error : String? = nil) : String
      counts = @d.store.expense_count_by_category
      archived, active = @d.store.list_categories(true).partition(&.archived?)
      rows = ->(categories : Array(Store::Category)) do
        categories.map_with_index do |c, i|
          Views::ListRow.new(c.id, c.name, counts.fetch(c.id, 0), first: i == 0, last: i == categories.size - 1)
        end
      end
      page(env, Views::Categories.new(rows.call(active), rows.call(archived), name), "Kategorien", Nav::Settings, status, error)
    end

    private def create_category(env : HTTP::Server::Context) : String
      @d.store.create_category(env.me.id, env.form("name"))
      redirect(env, CATEGORIES, "Kategorie „#{Store.normalize_name(env.form("name"))}“ hinzugefügt.")
    rescue ex : Domain::ValidationError
      show_categories(env, env.form("name"), 422, ex.msg)
    end

    private def rename_category(env : HTTP::Server::Context) : String
      @d.store.rename_category(env.me.id, find_category(env).id, env.form("name"))
      redirect(env, CATEGORIES, "Gespeichert.")
    rescue ex : Domain::ValidationError
      show_categories(env, "", 422, ex.msg)
    end

    private def archive_category(env : HTTP::Server::Context, archive : Bool) : String
      category = find_category(env)
      @d.store.set_category_archived(env.me.id, category.id, archive)
      redirect(env, CATEGORIES, "Kategorie „#{category.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
    end

    private def move_category(env : HTTP::Server::Context, up : Bool) : String
      category = find_category(env)
      or_404(env, "Kategorie nicht gefunden.") { @d.store.move_category(env.me.id, category.id, up) }
      redirect(env, "#{CATEGORIES}#kategorie-#{category.id}")
    end

    private def find_category(env : HTTP::Server::Context) : Store::Category
      or_404(env, "Kategorie nicht gefunden.") { @d.store.get_category(path_id(env)) }
    end
  end
end
