class Course < ApplicationRecord
  belongs_to :term

  has_many :sections, dependent: :destroy, inverse_of: :course
  has_many :registrations, dependent: :destroy
  has_many :users, through: :registrations

  has_many :reg_requests, dependent: :destroy

  has_many :assignments, dependent: :restrict_with_error
  has_many :submissions, through: :assignments
  has_many :teams,       dependent: :destroy
  has_many :teamsets, dependent: :destroy

  belongs_to :lateness_config

  validates :term_id, presence: true
  validates :lateness_config, presence: true
  validates :name, length: { minimum: 2 }, uniqueness: { scope: :term_id }
  validate  :has_sections

  accepts_nested_attributes_for :sections, allow_destroy: true
  accepts_nested_attributes_for :lateness_config

  after_create :register_profs

  def has_sections
    if sections.empty?
      errors.add(:sections, "can't be empty")
    end
  end

  def section_types
    self.sections.map(&:type).uniq.sort_by{|t| Section::types[t]}.map{|t| [t, Section::types[t]]}
  end

  def sections_by_type
    self.sections.group_by(&:type)
  end

  def register_profs
    # Can't do this before create, because self.id isn't set yet
    # Can't do this using just Registration.new and RegistrationSection.new, because
    # they aren't owned by anything owned by self, so they don't get saved
    if registrations.empty?
      sections.each do |sec|
        begin
          r = Registration.find_or_create_by(user_id: sec.instructor_id, course_id: self.id)
          r.role = "professor"
          r.show_in_lists = false
          r.new_sections = [sec.id]
          r.save!
        rescue Exception => e
          errors[:base] << "Could not register #{sec.instructor.name} for course: #{e}"
        end
        begin
          rs = RegistrationSection.create!(
            registration: r,
            section: sec
          )
        rescue Exception => e
          errors[:base] << "Could not register #{sec.instructor.name} for section #{sec.id}: #{e}"
        end
      end
    end
    raise ActiveRecord::Rollback if errors[:base].count > 0
  end

  def registered_by?(user, as: nil)
    return false if user.nil?
    registration = Registration.find_by_course_id_and_user_id(self.id, user.id)
    return false if registration.nil?
    if as
      as == registration.role
    else
      registration.role == 'assistant' || registration.role == 'professor'
    end
  end

  def active_registrations
    registrations.where(show_in_lists: true).joins(:user).order("users.last_name", "users.first_name")
  end

  def students
    users.where("registrations.role": RegRequest::roles["student"])
  end

  def students_with_registrations
    students.joins("JOIN registration_sections ON registrations.id = registration_sections.registration_id")
      .joins("JOIN sections ON registration_sections.section_id = sections.crn")
  end

  def users_with_drop_info(for_users = nil)
    look_for = users
    if for_users
      look_for = look_for.where(id: for_users.map(&:id))
    end
    look_for.select("users.*", "registrations.dropped_date as dropped_date", "registrations.id as reg_id")
  end

  def students_with_drop_info
    users_with_drop_info(students)
  end

  def professors
    users.where("registrations.role": RegRequest::roles["professor"])
  end

  def graders
    users.where("registrations.role": RegRequest::roles["grader"])
  end

  def staff
    users
      .where("registrations.role <> #{RegRequest::roles["student"]}")
      .where("registrations.dropped_date is null")
  end

  def first_professor
    professors.first
  end

  def assignments_sorted
    self.assignments.to_a.sort_by(&:due_date)
  end

  def all_partners
    team_users = TeamUser.where(team: teams).group_by(&:team_id)
    users_teams = teams.map do |t|
      team_users[t.id].map do |tu|
        [tu.user_id, t.id]
      end
    end.flatten(1).group_by(&:first).map{|k,v| [k,v.map(&:last)]}.to_h
    users_teams.map do |uid, tids|
      [uid, tids.map do |tid|
         team_users[tid].map{|tu| [tu.user_id, tid]}
       end.flatten(1).group_by(&:first).map{|k,v| [k,v.map(&:last)]}.to_h]
    end.to_h
  end

  def score_summary(for_students = nil)
    if for_students.nil?
      for_students = self.students
    end
    assns = self.assignments.where("available < ?", DateTime.current)
    open = assns.where("due_date > ?", DateTime.current)
    subs_by_user = UsedSub.where(user: for_students, assignment: assns)
      .joins(:submission)
      .select(:user_id, :assignment_id, :score)
      .group_by(&:user_id)
    assns = assns.map{|a| [a.id, a]}.to_h
    avail = assns.reduce(0) do |tot, kv| tot + kv[1].points_available end
    total_points = self.assignments.reduce(0) do |tot, a| tot + a.points_available end
    # assume a default of 100 points, but there might be extra credit assignments that push the total above 100
    remaining = [100.0, total_points].max - avail
    ans = self.users_with_drop_info(for_students).sort_by(&:sort_name).map do |s|
      dropped = s.dropped_date
      used = (subs_by_user[s.id] || []).map{|u| [u.assignment_id, u]}.to_h
      adjust = 0
      pending_names = []
      min = used.values.reduce(0.0) do |tot, sub| 
        if (assns[sub.assignment_id].points_available != 0)
          if sub.score.nil?
            adjust += assns[sub.assignment_id].points_available
            pending_names.push assns[sub.assignment_id].name
          end
          tot + ((sub.score || 0) * assns[sub.assignment_id].points_available / 100.0) 
        else
          tot
        end
      end
      cur = (100.0 * min) / (avail - adjust)
      max = min + remaining
      unsub_names = []
      unsubs = open.reduce(0.0) do |tot, o|
        if used[o.id].nil?
          unsub_names.push o.name
          tot + o.points_available
        else
          tot
        end
      end
      {s: s, dropped: dropped, min: min, cur: cur, max: max,
       pending: adjust, pending_names: pending_names,
       unsub: unsubs, unsub_names: unsub_names,
       remaining: remaining}
    end
    ans
  end

  def grading_assigned_for(user)
    GraderAllocation
      .where(who_grades_id: user.id)
      .where(course: self)
      .where(grading_completed: nil)
      .group_by(&:assignment_id)
  end

  def grading_done_for(user)
    GraderAllocation
      .where(who_grades_id: user.id)
      .where(course: self)
      .where.not(grading_completed: nil)
      .joins(:submission)
      .where("submissions.score": nil)
      .group_by(&:assignment_id)
  end

  def pending_grading
    # only use submissions that are being used for grading, but this may produce
    # duplicates for team submissions only pick submissions from this course
    # only pick non-staff submissions hang on to the assignment id only keep
    # unfinished graders sort the assignments
    Grade
      .joins("INNER JOIN used_subs ON grades.submission_id = used_subs.submission_id")
      .joins("INNER JOIN assignments ON used_subs.assignment_id = assignments.id")
      .joins("INNER JOIN registrations ON used_subs.user_id = registrations.user_id")
      .where("assignments.course_id": self.id)
      .select("grades.*", "used_subs.assignment_id", "assignments.due_date")
      .joins("INNER JOIN users ON used_subs.user_id = users.id")
      .distinct.select("users.name AS user_name")
      .where(score: nil)
      .where("registrations.role": Registration::roles["student"])
      .order("assignments.due_date", "users.name")
      .group_by{|r| r.assignment_id}
  end

  def abnormal_subs
    abnormals = {}
    people = self.users_with_drop_info.where("registrations.dropped_date IS ?", nil).to_a
    assns = self.assignments_sorted
    all_subs = Assignment.submissions_for(people, assns).group_by(&:assignment_id)
    used_subs = UsedSub.where(assignment_id: assns.map(&:id)).group_by(&:assignment_id)
    assns.each do |a|
      next unless all_subs[a.id]
      a_subs = all_subs[a.id].group_by(&:for_user)
      used = used_subs[a.id]&.map{|u| [u.user_id, u]}&.to_h
      people.each do |p|
        subs = a_subs[p.id]
        if (subs&.count.to_i > 0) && (used.nil? || used[p.id].nil?)
          abnormals[a] = [] unless abnormals[a]
          abnormals[a].push p
        end
      end
    end

    abnormals
  end

  def unpublished_grades
    Submission
      .joins("INNER JOIN used_subs ON submissions.id = used_subs.submission_id")
      .where("used_subs.assignment_id": assignments_sorted.map(&:id))
      .joins("INNER JOIN grades ON grades.submission_id = submissions.id")
      .where.not("grades.score": nil)
      .where("grades.available": false)
      .joins("INNER JOIN users ON used_subs.user_id = users.id")
      .order("users.name")
      .select("DISTINCT submissions.*", "users.name AS user_name")
  end
end
