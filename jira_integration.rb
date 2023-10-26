require 'faraday'
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

  def connection
    @base_url = "https://#{@credentials[:domain]}.atlassian.net"
    @headers = {
      'Authorization' => "Basic #{Base64.strict_encode64("#{@credentials[:username]}:#{@credentials[:token]}")}",
      'Accept' => 'application/json',
      'Content-Type' => 'application/json'
    }
    @connection = Faraday.new(url: @base_url) do |faraday|
      faraday.adapter Faraday.default_adapter
    end
  end

  def load_estimate
    json_data = File.read(@estimate_file)
    @estimate = JSON.parse(json_data)
  end

  def create_project
    exist_project_id = get_project
    return exist_project_id unless exist_project_id.nil?

    response = @connection.post do |req|
      req.url '/rest/api/3/project'
      req.headers = @headers
      req.body = @options.to_json
    end

    if response.success?
      project = JSON.parse(response.body)
      project['id']
    else
      @error = response.body
      nil
    end
  end

  def get_project
    response = @connection.get do |req|
      req.url "/rest/api/3/project/#{@options[:key]}"
      req.headers = @headers
    end

    if response.success?
      project = JSON.parse(response.body)
      project['id']
    else
      nil
    end
  end

  def valid_label(label_name, prefix)
    "#{prefix}#{label_name.gsub(',', ' /').gsub(' ', '_')}"
  end

  def label_list
    # Send a GET request to retrieve the labels
    response = @connection.get do |req|
      req.url "/rest/api/3/label"
      req.headers = @headers
    end
    # Check the response status code
    labels = []
  
    if response.success?
      response_json = JSON.parse(response.body)
      labels = response_json['values']
    end
    
    labels
  end

  def issue_list
    response = @connection.get do |req|
      req.url "/rest/api/3/search"
      req.headers = @headers
    end

    issues = []
    if response.success?
      issue_data = JSON.parse(response.body)      
      issues = issue_data['issues']
    end

    issues
  end

  def lssue_type_list
    # Send a GET request to retrieve the issue type
    response = @connection.get do |req|
      req.url "/rest/api/3/issuetype"
      req.headers = @headers
    end

    issue_types = []  
    if response.success?
      issue_types = JSON.parse(response.body)
    end
    
    issue_types
  end

  def issue_type_id(issue_type)
    filtered_types = lssue_type_list.select do |element|
      element["name"] == issue_type
    end
    
    if filtered_types.any?
      filtered_types[0]["id"]
    else
      nil
    end
  end

  def create_epic(project_id, epic_name)
    if issue_type_id("Epic").nil?
      @error = "Can't found Epic id."
      return
    end
    
    # Create the epic by sending a POST request
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

    response = @connection.post do |req|
      req.url '/rest/api/3/issue'
      req.headers = @headers
      req.body = epic_data.to_json
    end
  
    # Check the response status code
    if response.success?
      issue = JSON.parse(response.body)
      issue['key']
    else
      @error = response.body
      nil
    end
  end

  def exist_epic(project_id, epic_name)
    issue = issue_list.find do |element|
      element["fields"]["project"]["id"] == project_id && 
      element["fields"]["summary"] == epic_name && 
      element["fields"]["issuetype"]["name"] == "Epic"
    end

    return issue['key'] if issue

    nil
  end

  def create_issue(issue_data)    
    # Create the issue by sending a POST request
    response = @connection.post do |req|
      req.url '/rest/api/3/issue'
      req.headers = @headers
      req.body = issue_data.to_json
    end
  
    # Check the response status code
    if response.success?
      issue = JSON.parse(response.body)
      puts "Issue created successfully. Issue number: #{issue['id']}, Key: #{issue['key']}"
      issue['key']
    else
      @error = response.body
      nil
    end
  end

  def get_screen_id_from_screenscheme(scheme_id)
    response = @connection.get do |req|
      req.url "rest/api/3/screenscheme?id=#{scheme_id}"
      req.headers = @headers
    end

    if response.success?
      res = JSON.parse(response.body)
      screens = res['values']
      filtered_data = screens.select { |item| item["id"] == scheme_id }
      puts "Screen Value: #{filtered_data}"
      if filtered_data.any?
        filtered_data.first["screens"]["default"]
      else
        nil
      end
    else
      puts "#{response.body}"
      nil
    end
  end

  def get_field_id_from_screen_id(screen_id, field_name)
    response = @connection.get do |req|
      req.url "rrest/api/3/screens/#{screen_id}/availableFields"
      req.headers = @headers
    end

    if response.success?
      fields = JSON.parse(response.body)
      filtered_data = fields.select { |item| item["name"] == field_name }
      if filtered_data.any?
        filtered_data.first["id"]
      else
        nil
      end
    else
      puts "#{response.body}"
      nil
    end
  end

  def get_tab_id_from_screen_id(screen_id)
    response = @connection.get do |req|
      req.url 'rest/api/3/screens/#{screen_id}/tabs'
      req.headers = @headers
    end

    if response.success?
      tabs = JSON.parse(response.body)
      tab = tabs[0]
      puts "Success to get the Tab. HTTP Response Code: #{response.status}"
      puts "Tab: id: #{tab['id']}, name: #{tab['name']}"
      tab['id']
    else
      puts "#{response.body}"
      nil
    end
  end

  def add_field_to_screen_and_tab(screen_id, tab_id, field_id)
    body = {
      fieldId: field_id
    }
    response = @connection.post do |req|
      req.url "/rest/api/3/screens/#{screen_id}/tabs/#{tab_id}/fields"
      req.headers = @headers
      req.body = body.to_json
    end

    if response.success?
      field = JSON.parse(response.body)
      puts "Field added successfully. id: #{field['id']}, name: #{field['name']}"
    else
      puts "#{response.body}"
    end
  end

  def update_issue(issue_key, story_point)
    story_points_data = {
      fields: {
        customfield_10034: story_point.to_f
        # duedate: "2023-11-10"
      }
    }

    response = @connection.put do |req|
      req.url "/rest/api/3/issue/#{issue_key}"
      req.headers = @headers
      req.body = story_points_data.to_json
    end

    if response.success?
      puts "Story Points updated successfully for issue #{issue_key}"
    else
      puts "Failed to update Story Points. HTTP Response Code: #{response.status}"
      puts "Response Body: #{response.body}"
    end
  end

  def process_estimate
    project_id = create_project
    puts "project_id is #{project_id}."
    return if project_id.nil?

    @estimate.each do |section|
      section_name = valid_label(section["name"], "section_")
  
      section["task_groups"].each do |task_group|
        group_name = valid_label(task_group["name"], "task_group_")  
        epic_name = task_group["milestone"]

        epic_issue_key = exist_epic(project_id, epic_name)
        if epic_issue_key.nil?
          epic_issue_key = create_epic(project_id, epic_name)
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
          task_content = []
          
          if task['subtasks'].length > 0
            task_content.push({
              type: "paragraph", 
              content: [
                {
                  "text": "Subtasks:",
                  "type": "text"
                }
              ]
            })
            task_subtask_content = []
            task['subtasks'].each do |subtask|
              task_subtask_bullet_content = []
              task_subtask_bullet_content.push({type: "text", text: " #{subtask['name']}"})

              unless subtask['description'].nil?
                task_subtask_bullet_content.push({type: "hardBreak"})
                task_subtask_bullet_content.push({type: "text", text: "#{subtask['description']}"})
              end

              task_subtask_content.push({
                type: "listItem",
                content: [
                  {
                    type: "paragraph",
                    content: task_subtask_bullet_content
                  }
                ]
              })
            end

            task_content.push({
              type: "bulletList",
              content: task_subtask_content
            })
          end

          if task['stories'].length > 0
            task['stories'].each do |story|
              if task['subtasks'].length > 0
                task_content.push({type: "rule"})
              end

              task_content.push({
                type: "paragraph", 
                content: [
                  {
                    "text": "#{story['story']}",
                    "type": "text"
                  }
                ]
              })
              
              unless story["acceptance_criteria"].nil?
                task_stories_content = []
                task_stories_content.push({type: "text", text: "#{'=' * 30}"})
                task_stories_content.push({type: "hardBreak"})
                task_stories_content.push({type: "hardBreak"})
                task_stories_content.push({type: "text", text: "Acceptance Criteria:"})
                task_stories_content.push({type: "hardBreak"})
                task_stories_content.push({type: "text", text: "#{story['acceptance_criteria']}"})

                task_content.push({
                  type: "paragraph", 
                  content: task_stories_content
                })
              end

              if task['subtasks'].length == 0
                task_content.push({type: "rule"})
              end
            end
          end
  
          issue_data = {
            fields: {
              project: {
                id: project_id
              },
              summary: task_name,
              description: {
                type: "doc",
                version: 1,
                content: task_content
              },
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

          update_issue(issue_key, task_points) unless task_points.nil?

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
end

credentials = {
  token: 'xxx',
  username: 'xxx@xx.xx',
  domain: 'xxx'
}

options = {
  key: 'xxx',
  name: 'xxx',
  assigneeType: 'UNASSIGNED', # or 'PROJECT_LEAD',
  leadAccountId: 'xxx',
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
