require 'tracker_api'
require 'json'

class PivotalTrackerIntegration
  def self.process(credentials, options, estimate_file)
    obj = new(credentials, options, estimate_file)
    obj.run
  end

  def initialize(credentials, options, estimate_file)
    @credentials = credentials
    @options = options
    @estimate_file = estimate_file
    @estimate = []
    @error = nil
  end

  def run
    client
    load_estimate
    process_estimate
    return @error unless @error.nil?

    true
  end

  private

  def client
    @client = TrackerApi::Client.new(token: @credentials[:token])
  end

  def create_epic(project, epic_name)
    begin
      epic_data = {
        name: epic_name
      }
      project.create_epic(epic_data)
    rescue TrackerApi::Errors::ClientError => e
      @error = e.response[:body]
      nil
    end
  end

  def create_project
    exist_project = get_project
    return exist_project unless exist_project.nil?

    begin
      project = @client.post('/projects', {body: @options}).body
      @client.project(project['id'])
    rescue TrackerApi::Errors::ClientError => e
      @error = e.response[:body]
      nil
    end
  end

  def create_story(project, story_data)
    begin
      project.create_story(story_data)
    rescue TrackerApi::Errors::ClientError => e
      @error = e.response[:body]
      nil
    end
  end

  def exist_epic(project, epic_name)
    begin
      epics = @client.get("/projects/#{project['id']}/epics").body
      epics.find do |epic|
        epic['name'] == epic_name
      end
    rescue TrackerApi::Errors::ClientError => e
      puts "#{e.response[:body]}"
      nil
    end
  end

  def get_project
    begin
      @client.projects.find {|p| p["name"] == @options[:name]}
    rescue TrackerApi::Errors::ClientError => e
      puts "#{e.response[:body]}"
      nil
    end
  end

  def load_estimate
    json_data = File.read(@estimate_file)
    @estimate = JSON.parse(json_data)
  end

  def process_estimate
    project = create_project
    return if project.nil?
    puts "project: id: #{project['id']}, name: #{project['name']}"
    
    update_project(project)

    @estimate.each do |section|
      section_name = valid_label(section["name"], "section: ")
  
      section["task_groups"].each do |task_group|
        group_name = valid_label(task_group["name"], "task_group: ")  
        epic_name = task_group["milestone"]

        epic = exist_epic(project, epic_name)
        if epic.nil?
          epic = create_epic(project, epic_name)

          return if epic.nil?
        end
        epic_label = epic['label']['name']
        puts "epic: id: #{epic['id']}, name: #{epic['name']}"
  
        task_group["tasks"].each do |task|
          task_name = task["name"]
          task_description = task["description"]
          if task_description.nil?
            task_description = ""
          end

          task_points = task["points"]
          task_due_on = task["due_on"]
          task_attachments = task["attachments"]
          task_assignee = task["assignee"]
          task_collaborators = task["collaborators"]
  
          tasks = []
          if task['subtasks'].length > 0
            task['subtasks'].each do |subtask|              
              tasks.push({ description: "#{subtask['name']}: #{subtask['description']}" })
            end
          end
          
          task_content = "Due on: #{task["due_on"]}\n\n"
          if task['stories'].length > 0
            task['stories'].each do |story|
              task_content = "#{task_content}\n#{'-' * 30}\n\n"
              task_content = "#{task_content}#{story['story']}\n\n"
              unless story["acceptance_criteria"].nil?
                task_content = "#{task_content}#{'=' * 30}\n\n"
                task_content = "#{task_content}Acceptance Criteria:\n"
                task_content = "#{task_content}#{story['acceptance_criteria']}\n"
              end
            end
          end          

          story_data = {
            name: task_name,
            description: task_content,
            estimate: task_points,
            story_type: "feature",
            labels: [
              { name: epic_label },
              { name: section_name },
              { name: group_name }
            ],
            tasks: tasks
          }

          story = create_story(project, story_data)
          return unless story

          puts "story: id:#{story['id']}, name: #{story['name']}"
          upload_attachments(story, task_attachments) unless task_attachments.empty?
          update_assignee(project, story, task_assignee) unless task_assignee.nil?
          update_collaborators(project, story, task_collaborators) unless task_collaborators.empty?
        end
      end
    end
  end

  def project_membership(project, username)
    member = project.memberships.find {|m| m['person']['username'] == username}
    member['person']['id']
  end

  def story_points
    points = []
    @estimate.each do |section|
      section['task_groups'].each do |task_group|
        task_group['tasks'].each do |task|
          if task['points']
            points << task['points']
          end
        end
      end
    end
    points
  end

  def update_assignee(project, story, assignee)
    begin
      story[:owner_ids] = [project_membership(project, assignee)]
      story.save
    rescue TrackerApi::Errors::ClientError => e
      puts "#{e.response[:body]}"
    end
  end

  def upload_attachments(story, attachfiles)
    comment = {
      text: 'Attach Files:',
      files: attachfiles
    }
    begin
      story.create_comment(comment)
      puts "The attached files have been uploaded."
    rescue TrackerApi::Errors::ClientError => e
      puts "#{e.response[:body]}"
    end
  end

  def update_collaborators(project, story, collaborators)
    followers = []
    collaborators.each do |collaborator|
      followers << project_membership(project, collaborator)
    end

    return if followers.empty?

    begin
      story[:follower_ids] = followers
      story.save
    rescue TrackerApi::Errors::ClientError => e
      puts "#{e.response[:body]}"
    end
  end

  def update_project(project)
    unless story_points.empty?
      data = {
        point_scale_is_custom: true,
        point_scale: project['point_scale'].split(',').map(&:to_i).concat(story_points).uniq.sort.join(',')
      }
      begin
        @client.put("/projects/#{project['id']}", {body: data})
        puts "updated the settings of the project."
      rescue TrackerApi::Errors::ClientError => e
        puts "#{e.response[:body]}"
      end
    end
  end

  def valid_label(label_name, prefix)
    "#{prefix}#{label_name.gsub(',', ' /')}"
  end
end

credentials = {
  token: 'xxx' # api token
}

options = {
  name: 'xxx' # project name
}

estimate_file = "./estimate.json"
result = PivotalTrackerIntegration.process(credentials, options, estimate_file)
if result == true
  puts "Integration ran successfully."
else
  puts "Integration encountered an error. Check the logs for details."
  puts "#{result}"
end
