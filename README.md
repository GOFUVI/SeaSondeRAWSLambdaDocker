This is an example of how SeaSondeR can be used in AWS to process multiple files from one station.

# Instructions

##  Setting and creating your image

1. Clone this repository in your computer.
2. Copy your MeasPattern.txt file into the repository folder.
3. Build the image with `docker build -t [image name]:[tag] .` . This can take a while.

## Setting a AWS Lambda function that uses the image
4. Upload your image to AWS ECR.
5. Create your AWS Lambda function and point it to use your image.
6. Set the environment variables in AWS Lambda.

## Processing your files in AWS S3
7. Upload your spectra files to AWS S3