module Zipfelkasse::Web
  module Views
    record Who, participants : Array(Store::Participant), me : Store::Participant?, return_to : String, name : String do
      Web.view "web/who.ecr"
    end
  end

  # Whoever can open the app picks who they are; there is no login.
  class WhoController < Controller
    def register : Nil
      get("/wer") { |env| show(env, 200, Web.safe_return(env.query("zurueck")), "") }
      post("/wer") { |env| select_person(env) }
      post("/wer/neu") { |env| create_person(env) }
    end

    private def show(env : HTTP::Server::Context, status : Int32, return_to : String, name : String, error : String? = nil) : String
      view = Views::Who.new(@d.store.list_participants, env.me?, return_to, name)
      page(env, view, "Wer bist du?", status: status, error: error)
    end

    private def select_person(env : HTTP::Server::Context) : String
      return_to = Web.safe_return(env.form("zurueck"))
      id = Web.positive_id?(env.form("id"))
      person = id.try { |i| @d.store.get_participant?(i) }
      return show(env, 422, return_to, "", "Diese Person gibt es nicht (mehr).") if person.nil? || person.archived?
      env.identify_as(person.id)
      redirect(env, return_to)
    end

    private def create_person(env : HTTP::Server::Context) : String
      return_to = Web.safe_return(env.form("zurueck"))
      name = env.form("name")
      id = begin
        @d.store.join_as_participant(name)
      rescue ex : Domain::ValidationError
        return show(env, 422, return_to, name, ex.msg)
      end
      env.identify_as(id)
      redirect(env, return_to, "Willkommen!")
    end
  end
end
