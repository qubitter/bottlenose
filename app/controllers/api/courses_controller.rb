module Api
  class CoursesController < ApiController
    before_action -> { find_course(params[:id]) }, only: [:show]
    before_action :require_registered_user, only: [:show]
    before_action :require_admin_or_prof_ever, only: [:index]

    def index
      render json: serialize_active_courses(current_user.active_courses)
    end

    private

    def serialize_active_courses(active_courses)
      active_courses.map do |sem, courses|
        {
          term: sem,
          courses: courses.map { |c| serialize_course(c) }
        }
      end
    end

    def serialize_course(course)
      {
        id: course.id,
        name: course.name,
        prof: current_user.course_professor?(course)
      }
    end
  end
end
