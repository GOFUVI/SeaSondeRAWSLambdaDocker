
FROM public.ecr.aws/lambda/provided:al2
LABEL Name=readcsdocker Version=0.0.1


COPY --from=amazon/aws-cli:latest /usr/local/aws-cli/ /usr/local/aws-cli/
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws \
        /usr/local/bin/aws && \
    ln -s /usr/local/aws-cli/v2/current/bin/aws_completer \
        /usr/local/bin/aws_completer

ENV R_VERSION=4.4.0


RUN yum -y install wget git tar

RUN yum -y install https://archives.fedoraproject.org/pub/archive/epel/7/x86_64/Packages/e/epel-release-7-14.noarch.rpm \
  && wget https://cdn.rstudio.com/r/centos-7/pkgs/R-${R_VERSION}-1-1.x86_64.rpm \
  && yum -y install R-${R_VERSION}-1-1.x86_64.rpm \
  && rm R-${R_VERSION}-1-1.x86_64.rpm

ENV PATH="${PATH}:/opt/R/${R_VERSION}/bin/"

# System requirements for R packages

# RUN yum -y install openssl-devel
RUN yum -y install udunits2-devel



RUN Rscript -e "install.packages(c('httr', 'jsonlite', 'logger', 'remotes','R.utils'), repos = 'https://packagemanager.rstudio.com/all/__linux__/centos7/latest')"
RUN Rscript -e "remotes::install_github('mdneuzerling/lambdr')"
RUN Rscript -e "remotes::install_github('GOFUVI/SeaSondeR')"

RUN mkdir /lambda
COPY runtime.R /lambda
RUN chmod 755 -R /lambda

#### Script ENV ####

##### First Order Region Options ####

ENV SEASONDER_NSM = "2"

ENV SEASONDER_FDOWN = "10"

ENV SEASONDER_FLIM = "100"

ENV SEASONDER_NOISEFACT = "3.981072"

ENV SEASONDER_CURRMAX = "2"

ENV SEASONDER_REJECT_DISTANT_BRAGG = "TRUE"

ENV SEASONDER_REJECT_NOISE_IONOSPHERIC = "TRUE" 

ENV SEASONDER_REJECT_NOISE_IONOSPHERIC_THRESHOLD = "0"

##### MUSIC OPTIONS #####

ENV SEASONDER_DOPPLER_INTERPOLATION = "2"

ENV SEASONDER_PPMIN = "5"

ENV SEASONDER_PWMAX = "50"

##### S3 Path #####

ENV SEASONDER_S3_OUTPUT_PATH = ""


RUN printf '#!/bin/sh\ncd /lambda\nRscript runtime.R' > /var/runtime/bootstrap \
  && chmod +x /var/runtime/bootstrap

CMD ["run_tasks"]