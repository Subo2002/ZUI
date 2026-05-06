UI library written in zig. 
Doesn't do it's own rendering, or inputs, you just hand it the inputs you want to check against and it'll do that, and it'll output the final configuration of UI elelements for you to render.
Designed to start over every frame, and it'll do all it's computations after collecting all the wanted ui layout data, not immediatley. 
For a zig game I'm working on. 
