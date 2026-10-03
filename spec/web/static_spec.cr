require "../spec_helper"

describe Web::Static do
  it "defines the CSS classes the templates promise" do
    css = String.new(Web::Static::FILES["app.css"])
    %w(.container .main .site-header .site-header-inner .brand .whoami .tabs
      .card .card-header .card-title .card-description .card-content .card-footer
      .btn .btn-primary .btn-secondary .btn-outline .btn-ghost .btn-destructive .btn-sm .btn-lg .btn-block
      .form .field .field-error .help .table-wrap .alert .alert-success .alert-destructive
      .link-list .stack .stack-sm .row .muted .amount .positive .negative .sr-only).each do |name|
      {" ", ",", "{"}.any? { |next_char| css.includes?(name + next_char) }.should be_true, "app.css lacks #{name}"
    end
  end
end
