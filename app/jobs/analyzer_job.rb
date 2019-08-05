class AnalyzerJob < ApplicationJob
  def perform(notice)
    notice.photos.each do |photo|
      notice.latitude ||= photo.metadata[:latitude]
      notice.longitude ||= photo.metadata[:longitude]
      notice.date ||= photo.metadata[:date_time]

      result = annotator.annotate_object(photo.key)
      notice.registration ||= Annotator.grep_text(result) { |string| Vehicle.plate?(string) }.first
      notice.color ||= Annotator.dominant_colors(result).first
    end

    notice.reverse_geocode
    notice.status = :open
    notice.save_incomplete!
  end

  private

  def annotator
    @annotator ||= Annotator.new
  end
end