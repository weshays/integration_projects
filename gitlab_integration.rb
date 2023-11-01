require 'gitlab'

class GitlabIntegration
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
    connection
    load_estimate
    process_estimate
    return @error unless @error.nil?

    true
  end

  private

  def connection
    @client = Gitlab.client(@credentials)
  end

  def create_issue(project, title, issue_data)
    begin
      @client.create_issue(project['id'], title, issue_data)
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def create_label(project, name, color)
    exist_label = get_label(project, name)
    return exist_label unless exist_label.nil?

    begin
      @client.create_label(project['id'], name, color)
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def create_milestone(project, title)
    exist_milestone = get_milestone(project, title)
    return exist_milestone unless exist_milestone.nil?

    begin
      @client.create_milestone(project['id'], title)
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def create_project
    exist_project = get_project
    return exist_project unless exist_project.nil?

    begin
      @client.create_project(
        @options[:name], 
        description: @options[:description], 
        visibility: @options[:visibility]
      )
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def get_collaborators(collaborators)
    assignee_ids = []
    collaborators.each do |collaborator|
      assign_id = get_user(collaborator)
      assignee_ids << assign_id unless assign_id.nil?
    end

    assignee_ids
  end

  def get_label(project, name)
    begin
      @client.labels(project['id']).find{|m| m['name'] == name}
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def get_milestone(project, title)
    begin
      @client.milestones(project['id']).find{|m| m['title'] == title}
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def get_project
    begin
      @client.projects({membership: true}).find{|p| p['name'] == @options[:name]}
    rescue StandardError => e
      @error = e.message
      nil
    end
  end

  def get_user(username)
    begin
      user = @client.user_search(username)
      if user
        user.first['id']
      else
        nil
      end
    rescue StandardError => e
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

    @estimate.each do |section|
      section_name = valid_label(section["name"], "section: ")
      return if create_label(project, section_name, "#F4976C").nil?

      section["task_groups"].each do |task_group|
        group_name = valid_label(task_group["name"], "task_group: ")
        return if create_label(project, group_name, "#303C6C").nil?

        milestone_title = task_group["milestone"]
        milestone = create_milestone(project, milestone_title)
        puts "milestone = #{milestone}"
        return if milestone.nil?
  
        task_group["tasks"].each do |task|
          task_title = task["name"]
          task_assignee = task["assignee"]
          task_collaborators = task["collaborators"]
          task_attachments = task["attachments"]
          task_dueon = task["due_on"]
          task_dueon = "" if task_dueon.nil?
  
          unless task['points'].nil?
            task_title = "#{task_title} [#{task['points']}]"
          end
  
          task_content = ""  
          if task['subtasks'].length > 0
            task_content = "#{task_content}Subtasks:\n"
            task['subtasks'].each do |subtask|
              task_content = "#{task_content}- #{subtask['name']}\n"
              unless subtask['description'].nil?
                task_content = "#{task_content}  #{subtask['description']}\n"
              end
            end
          end
  
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

          unless task_attachments.empty?
            attach_files = upload_attachments(project, task_attachments)
            task_content = "#{task_content}\n\n#{attach_files}"
          end
  
          issue_data = {
            issue_type: 'issue',
            description: task_content, 
            milestone_id: milestone['id'],
            labels: [ section_name, group_name ].join(','),
            due_date: task_dueon
          }

          unless task_assignee.nil?
            issue_data[:assignee_id] = get_user(task_assignee)
          end

          unless task_collaborators.empty?
            issue_data[:assignee_ids] = get_collaborators(task_collaborators)
          end
  
          issue = create_issue(project, task_title, issue_data)
          return if issue.nil?
          puts "issue: id: #{issue['id']}, title: #{issue['title']}"          
        end
      end
    end
  end

  def upload_attachments(project, attachfiles)
    images = []
    attachfiles.each do |attachfile|
      begin
        attach = @client.upload_file(project['id'], attachfile)
        puts "The file has been uploaded. #{attach['markdown']}"
        images << attach['markdown']
      rescue StandardError => e
        puts "#{e.message}"
        false
      end
    end

    images.join(' ')
  end

  def valid_label(label_name, prefix)
    "#{prefix}#{label_name.gsub(',', ' /')}"
  end
end

credentials = {
  endpoint: 'https://gitlab.com/api/v4',
  private_token: 'xxx'
}

options = {
  name: 'xxx',
  description: 'xxx',
  visibility: 'public'
}

estimate_file = "./estimate.json"
result = GitlabIntegration.process(credentials, options, estimate_file)
if result == true
  puts "Integration ran successfully."
else
  puts "Integration encountered an error. Check the logs for details."
  puts "#{result}"
end
