class Putpaws::CloudWatch::DefaultLogFormatter
  attr_accessor :datetime_format
  def initialize(datetime_format: nil)
    @datetime_format = datetime_format || "%FT%T%:z"
  end

  def call(event)
    time = Time.at(0, event.timestamp, :millisecond)
    "%s %s\n" % [time.strftime(datetime_format), event.message]
  end
end
