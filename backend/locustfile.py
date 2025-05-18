
import random
from locust import HttpUser, task, between

class BackendUser(HttpUser):
    wait_time = between(1, 3)  # Users wait 1-3 seconds between tasks
    host = "http://10.224.0.62:5000"  # Internal LoadBalancer IP for backend

    # This list will store IDs of events created by this specific user instance.
    # It helps in making GET (specific), PUT, and DELETE operations more targeted.
    created_event_ids = []

    def on_start(self):
        """
        Called when a Locust user starts.
        Ensures created_event_ids is empty for a new user session.
        """
        self.created_event_ids = []

    @task(2)  # Weight: 2 - Create new events
    def create_event(self):
        event_data = {
            "name": f"Locust Event {random.randint(1, 100000)}",
            "date": f"2024-{random.randint(1,12):02d}-{random.randint(1,28):02d}", # YYYY-MM-DD
            "description": f"Load test event created by Locust {random.random()}"
        }
        response = self.client.post("/events", json=event_data)
        # Only append to created_event_ids if the POST was successful (HTTP 201 Created)
        if response is not None and response.status_code == 201:
            try:
                # Assuming the response JSON contains an 'id' field for the new event.
                event_id = response.json()["id"]
                self.created_event_ids.append(str(event_id))
            except (ValueError, KeyError, TypeError):
                pass # Silently ignore if parsing fails, Locust already logged HTTP success.

    @task(5)  # Weight: 5 - List all events (higher frequency)
    def list_events(self):
        self.client.get("/events")

    @task(5)  # Weight: 5 - Get a specific event (higher frequency)
    def get_specific_event(self):
        if self.created_event_ids:  # Only proceed if there are known event IDs
            event_id = random.choice(self.created_event_ids)
            # Use 'name' to group similar requests in Locust UI (e.g., /events/1, /events/2 -> /events/[id])
            self.client.get(f"/events/{event_id}", name="/events/[id]")
        # If created_event_ids is empty, this task does nothing for this iteration.

    @task(1)  # Weight: 1 - Update a specific event
    def update_specific_event(self):
        if self.created_event_ids:  # Only proceed if there are known event IDs
            event_id = random.choice(self.created_event_ids)
            updated_data = {
                "name": f"Updated Locust Event {random.randint(1, 100000)}",
                "date": f"2025-{random.randint(1,12):02d}-{random.randint(1,28):02d}",
                "description": f"This event was updated by Locust {random.random()}"
            }
            self.client.put(f"/events/{event_id}", json=updated_data, name="/events/[id]")
        # If created_event_ids is empty, this task does nothing.

    @task(1)  # Weight: 1 - Delete a specific event
    def delete_specific_event(self):
        # As requested: "do a list pick a random value and delete"
        list_response = self.client.get("/events", name="/events_for_delete_setup")
        event_id_to_delete = None

        if list_response.status_code == 200: # Check if listing events was successful
            try:
                events = list_response.json()
                if events:  # Ensure the list is not empty
                    event_to_delete = random.choice(events)
                    event_id_to_delete = str(event_to_delete["id"]) # Assuming 'id' key exists
            except (ValueError, KeyError, TypeError):
                pass
        
        if event_id_to_delete:
            self.client.delete(f"/events/{event_id_to_delete}", name="/events/[id]")
            # If the deleted ID was in our list, remove it.
            if event_id_to_delete in self.created_event_ids:
                self.created_event_ids.remove(event_id_to_delete)
        # If no event ID was found (e.g., list was empty or list call failed),
        # this task does nothing further for the delete operation.

# How to run this Locust test:
# 1. Ensure this file is saved as `locustfile.py` in your backend directory 
#    (e.g., d:/alt/al-kk-demo-apps/backend/locustfile.py).
# 2. Make sure your Flask backend application (app.py) is running and 
#    accessible (defaulting to http://localhost:5000).
# 3. Install Locust if you haven't already: `pip install locust`
# 4. Open your terminal, navigate to the `d:/alt/al-kk-demo-apps/backend/` directory.
# 5. Start Locust using the command: `locust -f locustfile.py`
#    (or just `locust` if the file is named `locustfile.py`).
# 6. Open your web browser and go to `http://localhost:8089` (the default Locust web UI).
# 7. Enter the total number of users you want to simulate and the spawn rate 
#    (how many users are started per second).
# 8. Click the "Start swarming" button.
