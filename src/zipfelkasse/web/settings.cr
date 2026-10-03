module Zipfelkasse::Web
  class Handlers
    record ParticipantRow, participant : Store::Participant, balance : Int64, expenses : Int32 do
      delegate id, name, to: participant
    end

    record CategoryRow, category : Store::Category, expenses : Int32, first : Bool, last : Bool do
      delegate id, name, to: category
    end

    def register_settings : Nil
      d = @d
      Web.route(d, "GET", "/einstellungen") { |r| render_settings(r, 200, @d.store.group_name, "") }
      Web.route(d, "POST", "/einstellungen") { |r| settings_save(r) }

      Web.route(d, "GET", "/einstellungen/teilnehmer") { |r| render_participants(r, 200, "", "") }
      Web.route(d, "POST", "/einstellungen/teilnehmer") { |r| participant_create(r) }
      Web.route(d, "POST", "/einstellungen/teilnehmer/:id") { |r| participant_rename(r) }
      Web.route(d, "POST", "/einstellungen/teilnehmer/:id/archivieren") { |r| participant_archive(r, true) }
      Web.route(d, "POST", "/einstellungen/teilnehmer/:id/reaktivieren") { |r| participant_archive(r, false) }

      Web.route(d, "GET", "/einstellungen/kategorien") { |r| render_categories(r, 200, "", "") }
      Web.route(d, "POST", "/einstellungen/kategorien") { |r| category_create(r) }
      Web.route(d, "POST", "/einstellungen/kategorien/:id") { |r| category_rename(r) }
      Web.route(d, "POST", "/einstellungen/kategorien/:id/archivieren") { |r| category_archive(r, true) }
      Web.route(d, "POST", "/einstellungen/kategorien/:id/reaktivieren") { |r| category_archive(r, false) }
      Web.route(d, "POST", "/einstellungen/kategorien/:id/hoch") { |r| category_move(r, true) }
      Web.route(d, "POST", "/einstellungen/kategorien/:id/runter") { |r| category_move(r, false) }
    end

    # group_name is the input as entered (after an error).
    private def render_settings(r : Request, status : Int32, group_name : String, error : String) : Nil
      r.page(status, Page.new(title: "Einstellungen", nav: NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "web/settings.ecr"
      end
    end

    def settings_save(r : Request) : Nil
      name = r.form_value("gruppenname")
      begin
        @d.store.set_group_name(r.me.id, name)
      rescue ex : Domain::ValidationError
        return render_settings(r, 422, name, ex.message || "")
      end
      r.set_flash("Gespeichert.")
      r.redirect("/einstellungen")
    end

    # name is the "new person" input after an error.
    private def render_participants(r : Request, status : Int32, name : String, error : String) : Nil
      people = @d.store.list_participants(true)
      balances = @d.store.balances
      counts = @d.store.expense_count_by_participant
      rows = people.map { |p| ParticipantRow.new(p, balances.fetch(p.id, 0_i64), counts.fetch(p.id, 0)) }
      archived, active = rows.partition(&.participant.archived?)
      me = r.me?
      r.page(status, Page.new(title: "Teilnehmer", nav: NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "web/participants.ecr"
      end
    end

    def participant_create(r : Request) : Nil
      name = r.form_value("name")
      begin
        @d.store.create_participant(r.me.id, name)
      rescue ex : Domain::ValidationError
        return render_participants(r, 422, name, ex.message || "")
      end
      r.set_flash("„#{Store.normalize_name(name)}“ hinzugefügt.")
      r.redirect("/einstellungen/teilnehmer")
    end

    def participant_rename(r : Request) : Nil
      old = load_participant(r)
      begin
        @d.store.rename_participant(r.me.id, old.id, r.form_value("name"))
      rescue ex : Domain::ValidationError
        return render_participants(r, 422, "", ex.message || "")
      end
      r.set_flash("Gespeichert.")
      r.redirect("/einstellungen/teilnehmer")
    end

    # The store refuses to archive a person with an open balance.
    def participant_archive(r : Request, archive : Bool) : Nil
      p = load_participant(r)
      begin
        @d.store.set_participant_archived(r.me.id, p.id, archive)
      rescue ex : Domain::ValidationError
        return render_participants(r, 422, "", ex.message || "")
      rescue Store::NotFound
        raise HTTPError.not_found("Person nicht gefunden.")
      end
      r.set_flash("„#{p.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
      r.redirect("/einstellungen/teilnehmer")
    end

    private def load_participant(r : Request) : Store::Participant
      @d.store.get_participant(r.path_id)
    rescue Store::NotFound
      raise HTTPError.not_found("Person nicht gefunden.")
    end

    # name is the "new category" input after an error.
    private def render_categories(r : Request, status : Int32, name : String, error : String) : Nil
      counts = @d.store.expense_count_by_category
      archived_cats, active_cats = @d.store.list_categories(true).partition(&.archived?)
      active = active_cats.map_with_index do |c, i|
        CategoryRow.new(c, counts.fetch(c.id, 0), i == 0, i == active_cats.size - 1)
      end
      archived = archived_cats.map { |c| CategoryRow.new(c, counts.fetch(c.id, 0), false, false) }
      r.page(status, Page.new(title: "Kategorien", nav: NAV_SETTINGS, error: error)) do |__io__|
        Web.template __io__, "web/categories.ecr"
      end
    end

    def category_create(r : Request) : Nil
      name = r.form_value("name")
      begin
        @d.store.create_category(r.me.id, name)
      rescue ex : Domain::ValidationError
        return render_categories(r, 422, name, ex.message || "")
      end
      r.set_flash("Kategorie „#{Store.normalize_name(name)}“ hinzugefügt.")
      r.redirect("/einstellungen/kategorien")
    end

    def category_rename(r : Request) : Nil
      old = load_category(r)
      begin
        @d.store.rename_category(r.me.id, old.id, r.form_value("name"))
      rescue ex : Domain::ValidationError
        return render_categories(r, 422, "", ex.message || "")
      end
      r.set_flash("Gespeichert.")
      r.redirect("/einstellungen/kategorien")
    end

    # Any store error here is a 500, validation included.
    def category_archive(r : Request, archive : Bool) : Nil
      c = load_category(r)
      @d.store.set_category_archived(r.me.id, c.id, archive)
      r.set_flash("Kategorie „#{c.name}“ #{archive ? "archiviert" : "reaktiviert"}.")
      r.redirect("/einstellungen/kategorien")
    end

    def category_move(r : Request, up : Bool) : Nil
      c = load_category(r)
      begin
        @d.store.move_category(r.me.id, c.id, up)
      rescue Store::NotFound
        raise HTTPError.not_found("Kategorie nicht gefunden.")
      end
      r.redirect("/einstellungen/kategorien#kategorie-#{c.id}")
    end

    private def load_category(r : Request) : Store::Category
      @d.store.get_category(r.path_id)
    rescue Store::NotFound
      raise HTTPError.not_found("Kategorie nicht gefunden.")
    end
  end
end
