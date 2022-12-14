from turtle import Turtle, Screen


ALIGNMENT = "center"
FONT = ("Courier", 24, "normal")
screen = Screen()

class Scoreboard(Turtle):

    def __init__(self):
        super().__init__()
        self.score = 0
        with open("my_file.txt") as data:
            self.high_score = int(data.read())
        self.color("white")
        self.penup()
        self.goto(0, 270)
        self.hideturtle()
        self.update_scoreboard()

    def update_scoreboard(self):
        self.clear()
        self.write(f"Score: {self.score} High Score: {self.high_score}", align=ALIGNMENT, font=FONT)

    def reset(self):
        if self.score > self.high_score:
            self.high_score = self.score
            with open("my_file.txt", mode="w") as data:
                data.write(f"{self.high_score}")
            screen.onkey(exit(),"K")
        self.score = 0
        self.update_scoreboard()

    def increase_score(self):
        self.score += 1
        self.update_scoreboard()
