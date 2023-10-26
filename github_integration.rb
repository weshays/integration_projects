require 'faraday'
require 'json'

class GithubIntegration
  def self.process(credentials, estimate_file)
    obj = new(credentials, estimate_file)
    obj.run
  end

  def initialize(credentials, estimate_file)
    @credentials = credentials
    @estimate_file = estimate_file
    @estimate = []
    @error = nil
  end

  def run
    # Add any error checking error.
    # return error if error.present?
    connection
    load_estimate
    process_estimate
    return @error unless @error.nil?

    true
  end

  private

  def connection
    @base_url = "/repos/#{@credentials[:owner]}/#{@credentials[:repo]}"
    @headers = {
      'Authorization' => "Bearer #{@credentials[:token]}",
      'Accept' => 'application/vnd.github.v3+json',
      'Content-Type' => 'application/json'
    }
    @connection = Faraday.new(url: 'https://api.github.com')
  end

  def create_issue(issue_data)
    # Create the issue by sending a POST request
    response = @connection.post("#{@base_url}/issues", issue_data.to_json, @headers)
  
    # Check the response status code
    if response.status == 201
      issue = JSON.parse(response.body)
      puts "Issue created successfully. Issue number: #{issue['number']}"
      true
    else
      puts "Failed to create the issue. Status code: #{response.status}"
      @error = response.body
      false
    end
  end
  
  def create_label(label_data)
    # Check if an element with the specified label exists
    label_exists = label_list.any? { |label| label['name'] == "#{label_data[:name]}" }
  
    unless label_exists
      # Send a POST request to create the label
      response = @connection.post("#{@base_url}/labels", label_data.to_json, @headers)
  
      # Check the response status code
      if response.status == 201
        label = JSON.parse(response.body)
        puts "Label created successfully. Name: #{label['name']}, Color: ##{label['color']}"
      else
        puts "Failed to create the label. Status code: #{response.status}, #{label_data[:name]}"
        puts response.body
      end
    end
  end
  
  def create_milestone(milestone_data)
    # Check if an element with the specified milestone exists
    found_milestone = milestone_list.find { |milestone| milestone['title'] == "#{milestone_data[:title]}" }
  
    if found_milestone
      found_milestone['number']
    else
      # Send a POST request to create the milestone
      response = @connection.post("#{@base_url}/milestones", milestone_data.to_json, @headers)
      milestone_number = 0
  
      # Check the response status code
      if response.status == 201
        milestone = JSON.parse(response.body)
        puts "Milestone created successfully. Title: #{milestone['title']}, Due Date: #{milestone['due_on']}"
        milestone_number = milestone['number']
      end
  
      milestone_number
    end
  end
  
  def label_list
    # Send a GET request to retrieve the labels
    response = @connection.get("#{@base_url}/labels", {}, @headers)
    # Check the response status code
    labels = []
  
    if response.status == 200
      labels = JSON.parse(response.body)
    end
    
    labels
  end

  def load_estimate
    json_data = File.read(@estimate_file)
    @estimate = JSON.parse(json_data)
  end
  
  def milestone_list
    # Send a GET request to retrieve the milestones
    response = @connection.get("#{@base_url}/milestones", {}, @headers)
    # Check the response status code
    milestones = []
  
    if response.status == 200
      milestones = JSON.parse(response.body)
    end
  
    milestones
  end
  
  def process_estimate
    @estimate.each do |section|
      section_name = valid_label(section["name"], "Section: ")
      create_label({ name: section_name, color: "F4976C" })
  
      section["task_groups"].each do |task_group|
        group_name = valid_label(task_group["name"], "Task Group: ")
        create_label({ name: group_name, color: "303C6C" })
  
        milestone = task_group["milestone"]
        milestone_number = create_milestone({ title: "#{milestone}", description: "" })
  
        task_group["tasks"].each do |task|
          task_title = task["name"]
  
          unless task['points'].nil?
            task_title = "#{task_title} [#{task['points']}]"
          end
  
          task_content = "Due on: #{task["due_on"]}\n\n"
  
          if task['subtasks'].length > 0
            task_content = "#{task_content} #{'-' * 30}\n\n"
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
            title: task_title, 
            body: task_content, 
            labels: [ section_name, group_name ],
            milestone: milestone_number
          }
  
          return unless create_issue(issue_data)
        end
      end
    end
  end
  
  def valid_label(label_name, prefix)
    max_length = 50
    "#{prefix} #{label_name.gsub(',', ' /')}"[0..max_length-1]
  end
end

credentials = {
  token: '',
  owner: '',
  repo: ''
}
estimate_file = "./estimate.json"
result = GithubIntegration.process(credentials, estimate_file)
if result == true
  puts "Integration ran successfully."
else
  puts "Integration encountered an error. Check the logs for details."
  puts "#{result}"
end