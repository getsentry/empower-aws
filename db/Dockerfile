FROM public.ecr.aws/docker/library/postgres:16-alpine
COPY empowerplant.sql seed.sh /seed/
RUN chmod +x /seed/seed.sh
ENTRYPOINT ["/seed/seed.sh"]
