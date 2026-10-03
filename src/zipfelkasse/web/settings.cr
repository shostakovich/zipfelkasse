module Zipfelkasse::Web
  module Views
    record ParticipantRow, participant : Store::Participant, balance : Int64, expenses : Int32 do
      delegate id, name, to: participant
    end

    record CategoryRow, category : Store::Category, expenses : Int32, first : Bool, last : Bool do
      delegate id, name, to: category
    end

    # group_name is the input as entered (after an error).
    record Settings, group_name : String do
      Web.view "web/settings.ecr"
    end

    # name is the "new person" input after an error.
    record Participants, active : Array(ParticipantRow), archived : Array(ParticipantRow), name : String,
      me : Store::Participant do
      Web.view "web/participants.ecr"
    end

    # name is the "new category" input after an error.
    record Categories, active : Array(CategoryRow), archived : Array(CategoryRow), name : String do
      Web.view "web/categories.ecr"
    end
  end

  class SettingsController < Controller
    def register : Nil
      get("/einstellungen") { |env| show_settings(env, @d.store.group_name) }
      post("/einstellungen") { |env| save_settings(env) }

      get("/einstellungen/teilnehmer") { |env| show_participants(env) }
      post("/einstellungen/teilnehmer") { |env| create_participant(env) }
      post("/einstellungen/teilnehmer/:id") { |env| rename_participant(env) }
      post("/einstellungen/teilnehmer/:id/archivieren") { |env| archive_participant(env, true) }
      post("/einstellungen/teilnehmer/:id/reaktivieren") { |env| archive_participant(env, false) }

      get("/einstellungen/kategorien") { |env| show_categories(env) }
      post("/einstellungen/kategorien") { |env| create_category(env) }
      post("/einstellungen/kategorien/:id") { |env| rename_category(env) }
      post("/einstellungen/kategorien/:id/archivieren") { |env| archive_category(env, true) }
      post("/einstellungen/kategorien/:id/reaktivieren") { |env| archive_category(env, false) }
      post("/einstellungen/kategorien/:id/hoch") { |env| move_category(env, true) }
      post("/einstellungen/kategorien/:id/runter") { |env| move_category(env, false) }
    end

    private def show_settings(env : HTTP::Server::Context, group_name : String, status = 200, error : String? = nil) : String
      page(env, Views::Settings.new(group_name), "Einstellungen", Nav::Settings, status, error)
    end

    private def save_settings(env : HTTP::Server::Context) : String
      name = env.form("gruppenname")
      begin
        @d.store.set_group_name(env.me.id, name)
      rescue ex : Domain::ValidationError
        return show_settings(env, name, 422, ex.msg)
      end
      redirect(env, "/einstellungen", "Gespeichert.")
    end

    private def show_participants(env : HTTP::Server::Context, name = "", status = 200, error : String? = nil) : String
      balances = @d.store.balances
      counts = @d.store.expense_count_by_participant
      rows = @d.store.list_participants(true).map do |p|
        Views::ParticipantRow.new(p, balances.fetch(p.id, 0_i64), counts.fetch(p.id, 0))
      end
      archived, active = rows.partition(&.participant.archived?)
      page(env, Views::Participants.new(active, archived, name, env.me), "Teilnehmer", Nav::Settings, status, error)
    end

    private def create_participant(env : HTTP::Server::Context) : String
      name = env.form("name")
      begin
        @d.store.create_participant(env.me.id, name)
      rescue ex : Domain::ValidationError
        return show_participants(env, name, 422, ex.msg)
      end
      redirect(env, "/einstellungen/teilnehmer", "„#{Store.normalize_name(name)}“ hinzugefügt.")
    end

    private def rename_participant(env : HTTP::Server::Context) : String
      person = find_participant(env)
      begin
        @d.store.rename_participant(env.me.id, person.id, env.form("name"))
      rescue ex : Domain::ValidationError
        return show_participants(env, "", 422, ex.msg)
      end
      redirect(env, "/einstellungen/teilnehmer", "Gespeichert.")
    end

    # The store refuses to archive a person with an open balance.
    private def archive_participant(env : HTTP::Server::Context, archive : Bool) : String
      person = find_participant(env)
      begin
        or_404(env, "Person nicht gefunden.") { @d.store.set_participant_archived(env.me.id, person.id, archive) }
      rescue ex : Domain::ValidationError
        return show_participants(env, "", 422, ex.msg)
      end
      redirect(env, "/einstellungen/teilnehmer", "„#{person.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
    end

    private def find_participant(env : HTTP::Server::Context) : Store::Participant
      id = path_id(env)
      or_404(env, "Person nicht gefunden.", id && @d.store.get_participant?(id))
    end

    private def show_categories(env : HTTP::Server::Context, name = "", status = 200, error : String? = nil) : String
      counts = @d.store.expense_count_by_category
      archived, active = @d.store.list_categories(true).partition(&.archived?)
      active_rows = active.map_with_index do |c, i|
        Views::CategoryRow.new(c, counts.fetch(c.id, 0), i == 0, i == active.size - 1)
      end
      archived_rows = archived.map { |c| Views::CategoryRow.new(c, counts.fetch(c.id, 0), false, false) }
      page(env, Views::Categories.new(active_rows, archived_rows, name), "Kategorien", Nav::Settings, status, error)
    end

    private def create_category(env : HTTP::Server::Context) : String
      name = env.form("name")
      begin
        @d.store.create_category(env.me.id, name)
      rescue ex : Domain::ValidationError
        return show_categories(env, name, 422, ex.msg)
      end
      redirect(env, "/einstellungen/kategorien", "Kategorie „#{Store.normalize_name(name)}“ hinzugefügt.")
    end

    private def rename_category(env : HTTP::Server::Context) : String
      category = find_category(env)
      begin
        @d.store.rename_category(env.me.id, category.id, env.form("name"))
      rescue ex : Domain::ValidationError
        return show_categories(env, "", 422, ex.msg)
      end
      redirect(env, "/einstellungen/kategorien", "Gespeichert.")
    end

    private def archive_category(env : HTTP::Server::Context, archive : Bool) : String
      category = find_category(env)
      @d.store.set_category_archived(env.me.id, category.id, archive)
      redirect(env, "/einstellungen/kategorien", "Kategorie „#{category.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
    end

    private def move_category(env : HTTP::Server::Context, up : Bool) : String
      category = find_category(env)
      or_404(env, "Kategorie nicht gefunden.") { @d.store.move_category(env.me.id, category.id, up) }
      redirect(env, "/einstellungen/kategorien#kategorie-#{category.id}")
    end

    private def find_category(env : HTTP::Server::Context) : Store::Category
      id = path_id(env)
      or_404(env, "Kategorie nicht gefunden.", id && @d.store.get_category?(id))
    end
  end
end
