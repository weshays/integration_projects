require 'jira-ruby'
require 'json'

class JiraIntegration
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

  def create_epic(project_id, epic_name)
    if issue_type_id("Epic").nil?
      @error = "Can't found Epic id."
      return
    end
    
    epic_data = {
      fields: {
        project: {
          id: project_id
        },
        summary: epic_name,
        issuetype: {
          id: issue_type_id("Epic")
        }
      },
      customfield_10011: epic_name
    }
    
    begin
      epic = @client.Issue.build
      epic.save(epic_data)

      puts "Epic created successfully. Issue number: #{epic.id}, Key: #{epic.key}"
      epic.key
    rescue JIRA::HTTPError => e
      @error = e.response.body
      nil
    end
  end

  def create_issue(issue_data)
    begin
      issue = @client.Issue.build  
      if issue.save(issue_data)
        puts "Issue created successfully. Issue number: #{issue.id}, Key: #{issue.key}"
        issue.key
      else
        @error = issue.errors
        nil
      end
    rescue JIRA::HTTPError => e
      @error = e.response.body
      nil
    end
  end

  def create_project
    exist_project_id = get_project
    return exist_project_id unless exist_project_id.nil?

    begin
      project = @client.Project.build
      project.save(@options)
      project.id
    rescue JIRA::HTTPError => e
      nil
    end
  end

  def connection
    @client = JIRA::Client.new(@credentials)
  end

  def exist_epic(project_id, epic_name)
    issue = issue_list.find do |issue|
      issue.fields['project']['id'] == project_id &&
      issue.summary == epic_name &&
      issue.issuetype.name == 'Epic'
    end

    return issue.key if issue

    nil
  end
  
  def field_id_from_screen_id(field_name)
    begin
      fields = @client.Field.all
      field = fields.find { |f| f.name == field_name }
      
      if field
        field.id
      else
        nil
      end
    rescue JIRA::HTTPError => e
      nil
    end
  end

  def get_project
    begin
      project = @client.Project.find(@options[:key])
      project.id
    rescue JIRA::HTTPError => e
      nil
    end
  end

  def issue_list
    begin
      jql = "project = #{@options[:key]}"
      issues = @client.Issue.jql(jql)
      issues
    rescue JIRA::HTTPError => e
      []
    end
  end

  def issue_type_id(issue_type)
    issue_types = issue_type_list
    issue_type = issue_types.find { |type| type.name == issue_type }

    return issue_type.id if issue_type

    nil
  end

  def issue_type_list
    begin
      issue_types = @client.Issuetype.all
  
      issue_types
    rescue JIRA::HTTPError => e
      []
    end
  end

  def label_list
    begin
      labels = @client.Label.all
  
      labels
    rescue JIRA::HTTPError => e
      @error = e.response.body
      []
    end
  end

  def lead_account_id
    begin
      user = @client.User.all.find({ "accountType" => "atlassian" }).first
      unless user.nil?
        @options[:leadAccountId] = user.accountId
        true
      else
        false
      end
    rescue JIRA::HTTPError => e
      @error = e.response.body
      false
    end
  end

  def load_estimate
    json_data = File.read(@estimate_file)
    @estimate = JSON.parse(json_data)
  end

  def upload_attachments(issue_key, attachment_paths)
    begin
      issue = @client.Issue.find(issue_key)
      attachment_paths.each do |attachment_path|
        if File.exist?(attachment_path)
          issue.attachments.build.save!(file: attachment_path)
        else
          puts "Attachment file not found: #{attachment_path}"
        end
      end
      puts "Attachments uploaded successfully."
    rescue JIRA::HTTPError => e
      puts "Failed to upload attachments. Error: #{@error}"
    end
  end

  def process_estimate
    return unless lead_account_id

    project_id = create_project

    return if project_id.nil?

    storypoint_field_id = field_id_from_screen_id("Story Points")
    duedate_field_id = field_id_from_screen_id("Due date")

    @estimate.each do |section|
      section_name = valid_label(section["name"], "section_")
  
      section["task_groups"].each do |task_group|
        group_name = valid_label(task_group["name"], "task_group_")  
        epic_name = task_group["milestone"]

        epic_issue_key = exist_epic(project_id, epic_name)
        puts "epic_issue_key = #{epic_issue_key}"
        if epic_issue_key.nil?
          epic_issue_key = create_epic(project_id, epic_name)
          puts "created epic key = #{epic_issue_key}"

          return if epic_issue_key.nil?

        end
  
        task_group["tasks"].each do |task|
          task_name = task["name"]
          task_description = task["description"]
          if task_description.nil?
            task_description = ""
          end

          task_points = task["points"]
          task_due_on = task["due_on"]
          task_attachments = task["attachments"]          
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
  
          issue_data = {
            fields: {
              project: {
                id: project_id
              },
              summary: task_name,
              description: task_content,
              assignee: {
                id: @options[:leadAccountId]
              },
              issuetype: {
                id: issue_type_id("Story")
              },
              parent: {
                "key": epic_issue_key
              },
              labels: [
                section_name,
                group_name
              ]
            }
          }

          issue_key = create_issue(issue_data)
          return unless issue_key

          unless storypoint_field_id == false
            update_issue(issue_key, storypoint_field_id, task_points) unless task_points.nil?
          end

          unless duedate_field_id == false
            update_issue(issue_key, duedate_field_id, task_due_on) unless task_due_on.nil?
          end

          upload_attachments(issue_key, task_attachments)

          task['subtasks'].each do |subtask|
            issue_data = {
              fields: {
                project: {
                  id: project_id
                },
                summary: "#{subtask['name']} :: #{subtask['description']}",
                assignee: {
                  id: @options[:leadAccountId]
                },
                issuetype: {
                  id: issue_type_id("Task")
                },
                parent: {
                  "key": epic_issue_key
                },
                labels: [
                  section_name,
                  group_name
                ]
              }
            }

            issue_key = create_issue(issue_data)
            return unless issue_key
            
          end
        end
      end
    end
  end

  def update_issue(issue_key, field_id, field_value)
    begin
      issue = @client.Issue.find(issue_key)
      if issue.save("fields" => { field_id => field_value })
        issue.key
      else
        nil
      end
    rescue JIRA::HTTPError => e
      nil
    end
  end

  def valid_label(label_name, prefix)
    "#{prefix}#{label_name.gsub(',', ' /').gsub(' ', '_')}"
  end
end

credentials = {
  :site               => 'http://xxxx.atlassian.net:443/',
  :context_path       => '',
  :username           => 'xxx@xxx.xxx',
  :password           => 'xxx',
  :auth_type          => :basic
}

options = {
  key: 'xxx',
  name: 'xxx',
  assigneeType: 'UNASSIGNED', # 'PROJECT_LEAD',
  projectTypeKey: 'software',
  projectTemplateKey: 'com.pyxis.greenhopper.jira:gh-simplified-kanban-classic',
  description: 'xxx'
}

estimate_file = "./estimate.json"
result = JiraIntegration.process(credentials, options, estimate_file)
if result == true
  puts "Integration ran successfully."
else
  puts "Integration encountered an error. Check the logs for details."
  puts "#{result}"
end
