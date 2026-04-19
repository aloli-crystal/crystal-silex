require "./spec_helper"

describe Silex do
  it "expose une version" do
    Silex::VERSION.should eq("0.1.0")
  end
end
